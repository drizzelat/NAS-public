#!/usr/bin/env bash
# When the image a stack host pulls for <ref> was built: its config's `created`, as epoch seconds.
# Prints nothing when that cannot be read or is implausible. Docs: docs/runbooks/setup-operations/renovate-pr-review.md
set -uo pipefail

file="${1:?usage: image-age.sh <compose-file> <image-ref>}"
ref="${2:?usage: image-age.sh <compose-file> <image-ref>}"
# shellcheck source=scripts/review/registry.sh
. "$(dirname "$0")/registry.sh"

dig="$(ref_digest "$ref")"
[ -n "$dig" ] || exit 0
reg="$(api_host "$(ref_registry "$ref")")"
repo="$(ref_repo "$ref")"
tok="$(auth_token "$reg" "$repo")"
man="$(get_manifest "$reg" "$repo" "$dig" "$tok")" || exit 0
child="$(child_for_arch "$man" "$(arch_for_file "$file")")"
if [ -n "$child" ]; then
  man="$(get_manifest "$reg" "$repo" "$child" "$tok")" || exit 0
fi
cfg="$(jq -r '.config.digest // empty' <<<"$man")"
[ -n "$cfg" ] || exit 0
created="$(get_blob "$reg" "$repo" "$cfg" "$tok" | jq -r '.created // empty' 2>/dev/null)"
[ -n "$created" ] || exit 0
epoch="$(date -u -d "$created" +%s 2>/dev/null)" || exit 0
# Reproducible builds stamp 1970, and a future date is a broken clock: neither dates the release.
if [ "$epoch" -lt 1420070400 ] || [ "$epoch" -gt "$(( $(date -u +%s) + 3600 ))" ]; then
  exit 0
fi
echo "$epoch"
