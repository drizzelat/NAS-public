#!/usr/bin/env bash
# Explain what a digest-only image bump actually changed: resolve both digests
# through the registry API and diff them. Docs: docs/runbooks/setup-operations/renovate-pr-review.md
set -euo pipefail

BASE="${1:?usage: renovate-image-delta.sh <base-sha> <head-sha>}"
HEAD="${2:?usage: renovate-image-delta.sh <base-sha> <head-sha>}"

# shellcheck source=scripts/review/registry.sh
. "$(dirname "$0")/review/registry.sh"

# Flatten the interesting bits of a config blob into a comparable shape.
summarize_config() {  # config-json
  jq -c '{
    created: .created,
    labels: (.config.Labels // {} | with_entries(
               select(.key | test("^org\\.opencontainers\\.image\\.(version|revision|base\\.name|created)$")))),
    versions: [ (.config.Env // [])[]
                | select(test("^[A-Z0-9_]*(VERSION|_MAJOR)=")) ] | sort,
    layers: (.rootfs.diff_ids // [])
  }' <<<"$1"
}

# ---------------------------------------------------------------- diff the PR

# Changed image lines per compose file, paired by repo so a tag change still
# matches its predecessor. An image only added or removed is reported, not diffed.
mapfile -t FILES < <(git diff --name-only "$BASE" "$HEAD" -- 'stacks/**/docker-compose.yml' | sort -u)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No stack compose files changed — nothing to inspect."
  echo
  echo "DELTA: NOOP"
  exit 0
fi

verdict="NOOP"
report=""
inspected=0

note() { report+="$1"$'\n'; }

for file in "${FILES[@]}"; do
  arch="$(arch_for_file "$file")"

  # Removed/added `image:` values for this file, keyed by repo.
  declare -A OLD=() NEW=()
  while IFS= read -r line; do
    ref="$(sed -E 's/^[-+][[:space:]]*image:[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")"
    [ -n "$ref" ] || continue
    key="$(ref_registry "$ref")/$(ref_repo "$ref")"
    case "$line" in
      -*) OLD[$key]="$ref" ;;
      +*) NEW[$key]="$ref" ;;
    esac
  done < <(git diff -U0 "$BASE" "$HEAD" -- "$file" | grep -E '^[-+][[:space:]]*image:[[:space:]]' || true)

  [ "${#NEW[@]}" -eq 0 ] && continue

  for key in "${!NEW[@]}"; do
    new_ref="${NEW[$key]}"
    old_ref="${OLD[$key]:-}"
    inspected=$((inspected + 1))

    short="${key#docker.io/}"; short="${short#library/}"
    if [ -z "$old_ref" ]; then
      note "### \`$short\` — new image in \`$file\`"
      note ""
      note "Added: \`$(ref_tag "$new_ref")\` — no predecessor to diff."
      note ""
      verdict="CHANGED"
      continue
    fi

    old_tag="$(ref_tag "$old_ref")"; new_tag="$(ref_tag "$new_ref")"
    old_dig="$(ref_digest "$old_ref")"; new_dig="$(ref_digest "$new_ref")"

    note "### \`$short\` (\`$file\`, $arch)"
    note ""

    if [ "$old_tag" != "$new_tag" ]; then
      note "Tag \`$old_tag\` → \`$new_tag\` — Renovate reports this one with release notes above."
    fi

    if [ -z "$old_dig" ] || [ -z "$new_dig" ]; then
      note "Not digest-pinned — cannot resolve content. \`$old_ref\` → \`$new_ref\`"
      note ""
      verdict="UNKNOWN"
      continue
    fi
    if [ "$old_dig" = "$new_dig" ]; then
      note "Digest unchanged."
      note ""
      continue
    fi

    reg="$(api_host "$(ref_registry "$new_ref")")"; repo="$(ref_repo "$new_ref")"
    tok="$(auth_token "$reg" "$repo")"

    old_man="$(get_manifest "$reg" "$repo" "$old_dig" "$tok" || true)"
    new_man="$(get_manifest "$reg" "$repo" "$new_dig" "$tok" || true)"
    if [ -z "$old_man" ] || [ -z "$new_man" ]; then
      note "Could not fetch manifests from \`$reg\` — inspect by hand."
      note ""
      verdict="UNKNOWN"
      continue
    fi

    old_child="$(child_for_arch "$old_man" "$arch")"
    new_child="$(child_for_arch "$new_man" "$arch")"
    # Single-arch image: the manifest we already hold IS the platform manifest.
    [ -z "$old_child" ] && old_child="$old_dig"
    [ -z "$new_child" ] && new_child="$new_dig"

    if [ "$old_child" = "$new_child" ]; then
      note "**NO-OP for $arch.** Index digest \`${old_dig:7:7}\` → \`${new_dig:7:7}\`, but both"
      note "resolve to the same $arch manifest \`${new_child:7:19}\` — the multi-arch index moved"
      note "because another platform or an attestation blob changed. The image this host"
      note "pulls is byte-identical. Safe to merge without further review."
      note ""
      continue
    fi

    verdict="CHANGED"

    old_cfg_d="$(get_manifest "$reg" "$repo" "$old_child" "$tok" | jq -r '.config.digest // empty')"
    new_cfg_d="$(get_manifest "$reg" "$repo" "$new_child" "$tok" | jq -r '.config.digest // empty')"
    if [ -z "$old_cfg_d" ] || [ -z "$new_cfg_d" ]; then
      note "$arch manifest changed \`${old_child:7:12}\` → \`${new_child:7:12}\`, but the config blob could not be read."
      note ""
      verdict="UNKNOWN"
      continue
    fi

    old_sum="$(summarize_config "$(get_blob "$reg" "$repo" "$old_cfg_d" "$tok")")"
    new_sum="$(summarize_config "$(get_blob "$reg" "$repo" "$new_cfg_d" "$tok")")"

    note "$arch image changed: \`${old_child:7:12}\` → \`${new_child:7:12}\`"
    note ""
    note '| Field | Before | After |'
    note '| --- | --- | --- |'

    row() { note "| $1 | \`$2\` | \`$3\` |"; }

    row "built" \
      "$(jq -r '.created // "?"' <<<"$old_sum")" \
      "$(jq -r '.created // "?"' <<<"$new_sum")"

    # Union of interesting label/env keys, so a key appearing or vanishing shows.
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      ov="$(jq -r --arg k "$k" '.labels[$k] // ""' <<<"$old_sum")"
      nv="$(jq -r --arg k "$k" '.labels[$k] // ""' <<<"$new_sum")"
      # Some images ship the label declared but empty (authentik's revision).
      [ -n "$ov$nv" ] || continue
      row "$k" "${ov:-—}" "${nv:-—}"
    done < <(jq -r -s '[.[0].labels, .[1].labels] | add | keys[]' <<<"$old_sum"$'\n'"$new_sum")

    # Upstream version env vars — the giveaway when a tag hides a real version bump.
    old_v="$(jq -r '.versions | join(", ") | if . == "" then "—" else . end' <<<"$old_sum")"
    new_v="$(jq -r '.versions | join(", ") | if . == "" then "—" else . end' <<<"$new_sum")"
    if [ "$old_v" != "—" ] || [ "$new_v" != "—" ]; then
      row "version env" "$old_v" "$new_v"
    fi

    changed_layers="$(jq -r -s '
      (.[0].layers) as $a | (.[1].layers) as $b
      | "\(([$b[] | select(. as $x | $a | index($x) | not)] | length))/\($b | length)"' \
      <<<"$old_sum"$'\n'"$new_sum")"
    note "| layers rebuilt | | \`$changed_layers\` |"
    note ""

    # Only alarming when the TAG did not move: a tag bump already carries release notes.
    if [ "$old_tag" = "$new_tag" ] && [ "$old_v" != "$new_v" ]; then
      note "⚠️ **Upstream version changed inside the same tag.** Read the release notes for \`$new_v\` before merging."
      note ""
    fi
  done
  unset OLD NEW
done

if [ "$inspected" -eq 0 ]; then
  echo "Compose files changed but no \`image:\` lines did."
  echo
  echo "DELTA: NOOP"
  exit 0
fi

printf '%s' "$report"
echo
echo "DELTA: $verdict"
