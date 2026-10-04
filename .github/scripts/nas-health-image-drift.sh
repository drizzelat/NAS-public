#!/usr/bin/env bash
# Check 14's digest comparison for .github/nas-health-check.md, as one command, so the
# agent reads findings instead of every container and every compose pin. From the repo root:
#   .github/scripts/nas-health-image-drift.sh <nas-lan-ip>
# Env: KOMODO_URL, KOMODO_API_KEY/_SECRET (probe-read), KOMODO_RESOLVE, NAS_SSH_KEY_FILE.
# Compose files go through the probe's yaml2json verb (no YAML parser on the runner). Read-only.
set -euo pipefail

nas="${1:?usage: nas-health-image-drift.sh <nas-lan-ip>}"
# shellcheck source=scripts/komodo/lib.sh
. "$(dirname "$0")/../../scripts/komodo/lib.sh"

probe() {
  ssh -i "$NAS_SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "nashealth@$nas" "$@"
}

declare -A pin=() stack_state=() digests=() untracked=()
servers=0 checked=0 drift=0 no_service=0 unpinned=0 errors=0

# pin["<folder>/<service>"] = image string from the repo compose file.
load_stack() {
  local json rows svc image
  if ! json="$(probe yaml2json < "stacks/$1/docker-compose.yml")" \
    || ! rows="$(jq -r '.services // {} | to_entries[] | [.key, (.value.image // "-")] | @tsv' <<<"$json")"; then
    stack_state["$1"]=error
    echo "ERROR  stacks/$1/docker-compose.yml: yaml2json failed, its containers are unchecked"
    errors=$((errors + 1))
    return
  fi
  while IFS=$'\t' read -r svc image; do
    if [[ -n "$svc" ]]; then pin["$1/$svc"]="$image"; fi
  done <<<"$rows"
  stack_state["$1"]=ok
}

# limit 0: every Komodo list call otherwise stops at a page of 50, silently.
if ! server_rows="$(kapi read/ListServers '{"limit":0}' | jq -r '.[] | .name')"; then
  echo "ERROR  Komodo ListServers failed, nothing checked"
  exit 1
fi

while IFS= read -r server; do
  [[ -n "$server" ]] || continue
  servers=$((servers + 1))
  # Running containers only. The list carries no labels, so each container is inspected.
  if ! names="$(kapi read/ListDockerContainers "$(jq -nc --arg s "$server" '{server:$s}')" \
      | jq -r '.[] | select(.state == "running") | .name')"; then
    echo "ERROR  server $server: ListDockerContainers failed, server unchecked"
    errors=$((errors + 1))
    continue
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! row="$(kapi read/InspectContainer "$(jq -nc --arg s "$server" --arg c "$name" '{server:$s,container:$c}')" \
        | jq -r '[(.Config.Labels["com.docker.compose.project"] // "-"),
                  (.Config.Labels["com.docker.compose.service"] // "-"), .Image] | @tsv')"; then
      echo "ERROR  $name (server $server): InspectContainer failed, unchecked"
      errors=$((errors + 1))
      continue
    fi
    IFS=$'\t' read -r project service image_id <<<"$row"
    # Stack name first, then a TrueNAS custom app's project ix-<app>, then <server>-<project>
    # (a periphery runs as project periphery, filed under stacks/<server>-periphery).
    folder=""
    if [[ "$project" != - ]]; then
      for candidate in "$project" "${project#ix-}" "$server-$project"; do
        if [[ -f "stacks/$candidate/docker-compose.yml" ]]; then
          folder="$candidate"
          break
        fi
      done
    fi
    if [[ -z "$folder" ]]; then
      untracked["server $server project $project"]+=" $name"
      continue
    fi

    [[ -n "${stack_state[$folder]:-}" ]] || load_stack "$folder"
    [[ "${stack_state[$folder]}" == ok ]] || continue

    image="${pin[$folder/$service]:-}"
    if [[ -z "$image" ]]; then
      echo "NO SERVICE  $name (server $server): service '$service' is running but not in stacks/$folder/docker-compose.yml"
      no_service=$((no_service + 1))
      continue
    fi
    if [[ "$image" != *@sha256:* ]]; then
      unpinned=$((unpinned + 1))
      continue
    fi
    want="${image##*@}"

    # Match the pin against RepoDigests, never ImageID: that is the config digest.
    key="$server/$image_id"
    if [[ -z "${digests[$key]+set}" ]]; then
      if ! digests["$key"]="$(kapi read/InspectImage "$(jq -nc --arg s "$server" --arg i "$image_id" '{server:$s,image:$i}')" \
          | jq -r '[.RepoDigests[]? | sub("^[^@]*@"; "")] | unique | join(",")')"; then
        echo "ERROR  $name (server $server): InspectImage $image_id failed, unchecked"
        errors=$((errors + 1))
        unset 'digests[$key]'
        continue
      fi
    fi
    running="${digests[$key]}"
    checked=$((checked + 1))
    if [[ ",$running," == *",$want,"* ]]; then
      continue
    fi

    drift=$((drift + 1))
    since="$(git log -1 --format=%ad --date=short -S"$want" -- "stacks/$folder/docker-compose.yml")"
    if [[ -n "$since" ]]; then
      age="drifting since $since ($(( ($(date -u +%s) - $(date -u -d "$since" +%s)) / 86400 ))d)"
    else
      age="pinned digest not found in git history"
    fi
    echo "DRIFT  $folder/$service ($name, server $server): ${image%@*} pinned $want, running ${running:-no RepoDigests}; $age"
  done <<<"$names"
done <<<"$server_rows"

if [[ ${#untracked[@]} -gt 0 ]]; then
  while IFS= read -r k; do
    echo "NO REPO COMPOSE  $k:${untracked[$k]}"
  done < <(printf '%s\n' "${!untracked[@]}" | sort)
fi

echo "SUMMARY  $servers servers, $checked digest-pinned running containers: $drift drift, $no_service no service, ${#untracked[@]} projects without repo compose, $unpinned not digest-pinned (skipped), $errors errors"
