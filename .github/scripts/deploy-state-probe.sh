#!/usr/bin/env bash
# Deterministic "the estate matches the repo" gate for the Komodo migration; exit 1 on any FAIL.
# Usage, env and what each check means: docs/runbooks/setup-operations/deploy-state-probe.md
set -euo pipefail

nas="${1:?usage: deploy-state-probe.sh <nas-lan-ip>}"
: "${KOMODO_URL:?}" "${KOMODO_API_KEY:?}" "${KOMODO_API_SECRET:?}" "${NAS_SSH_KEY_FILE:?}"
[[ -d stacks ]] || { echo "run from the repo root" >&2; exit 2; }
# shellcheck source=scripts/komodo/lib.sh
. scripts/komodo/lib.sh

# Applied by hand, never Komodo Stacks: the Komodo peripheries Komodo deploys through.
HAND_APPLIED="nas-periphery a1-vps-periphery micro-vps-periphery runner-vm-periphery"

fails=0
report=""
say() { echo "$1"; report+="$1"$'\n'; }
fail() { say "FAIL  $*"; fails=$((fails + 1)); }
pass() { say "PASS  $*"; }

finish() {
  say "RESULT  $fails failure(s)"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    verdict=PASS
    [[ $fails -eq 0 ]] || verdict="FAIL ($fails)"
    fence='```'
    printf '## deploy-state-probe: %s\n\n%s\n%s%s\n' "$verdict" "$fence" "$report" "$fence" >>"$GITHUB_STEP_SUMMARY"
  fi
  exit $((fails > 0 ? 1 : 0))
}

probe() {
  ssh -i "$NAS_SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "nashealth@$nas" "$@"
}

# limit 0 on every list call: Komodo otherwise returns a page of 50 and says nothing.
declare -A server_name=() stack_server=() stack_state=() want_server=()
if ! rows="$(kapi read/ListServers '{"limit":0}' | jq -r '.[] | [.id, .name, .info.state] | @tsv')"; then
  fail "Komodo ListServers failed, nothing checked"
  # 7. The deterministic half of the nightly health check: snapshots, scrubs, dumps,
# certs, the on-host clone, the boot guard, the Storage Box.
det_rc=0
det_out="$(.github/scripts/nas-deterministic-checks.sh "$nas")" || det_rc=$?
while IFS= read -r line; do
  [[ -n "$line" && "$line" != RESULT* ]] || continue
  say "$line"
  [[ "$line" != FAIL* ]] || fails=$((fails + 1))
done <<<"$det_out"
[[ $det_rc -eq 0 || $det_rc -eq 1 ]] || fail "nas-deterministic-checks.sh exited $det_rc"

finish
fi
while IFS=$'\t' read -r id name state; do
  [[ -n "$id" ]] || continue
  server_name["$id"]="$name"
  [[ "$state" == Ok ]] || fail "server $name is $state in Komodo"
done <<<"$rows"
for n in nas micro-vps a1-vps runner-vm; do
  [[ " ${server_name[*]} " == *" $n "* ]] || fail "no Komodo Server named $n"
done

# The server each Stack is declared on. komodo is self-managed and not in the ResourceSync.
while IFS=$'\t' read -r name server; do
  want_server["$name"]="$server"
done < <(awk '/^\[\[/ { s = ($0 == "[[stack]]") ; name = "" }
  s && /^name = / { gsub(/"/, "", $3); name = $3 }
  s && /^server = / && name != "" { gsub(/"/, "", $3); print name "\t" $3 }' komodo/resources.toml)
want_server[komodo]=nas

# 1. Placement: every folder is a running Komodo Stack on its declared server, and the reverse.
before=$fails
if ! stacks="$(kapi read/ListStacks '{"limit":0}' | jq -r '.[] | [.name, .info.server_id, .info.state] | @tsv')"; then
  fail "Komodo ListStacks failed, placement unchecked"
else
  while IFS=$'\t' read -r name sid state; do
    [[ -n "$name" ]] || continue
    stack_server["$name"]="${server_name[$sid]:-unknown server $sid}"
    stack_state["$name"]="$state"
  done <<<"$stacks"
  folders=0
  for f in stacks/*/docker-compose.yml; do
    s="${f#stacks/}"
    s="${s%/docker-compose.yml}"
    if [[ " $HAND_APPLIED " == *" $s "* ]]; then
      [[ -z "${stack_server[$s]:-}" ]] || fail "stacks/$s is applied by hand, but a Komodo Stack $s exists"
      continue
    fi
    folders=$((folders + 1))
    if [[ -z "${stack_server[$s]:-}" ]]; then
      fail "stacks/$s has no Komodo Stack"
      continue
    fi
    if [[ -z "${want_server[$s]:-}" ]]; then
      fail "stacks/$s has no [[stack]] entry with a server in komodo/resources.toml"
    elif [[ "${stack_server[$s]}" != "${want_server[$s]}" ]]; then
      fail "stack $s is on ${stack_server[$s]}, komodo/resources.toml declares ${want_server[$s]}"
    fi
    if [[ "$s" == github-runner && "${stack_state[$s]}" == deploying ]]; then
      # This job runs on that runner, and the Stack's pre_deploy waits for the job to end (github-runner.md).
      say "NOTE  stack github-runner is deploying: its pre_deploy is waiting for this job to finish"
    else
      [[ "${stack_state[$s]}" == running ]] || fail "stack $s is ${stack_state[$s]} in Komodo, not running"
    fi
  done
  for s in "${!stack_server[@]}"; do
    [[ -f "stacks/$s/docker-compose.yml" ]] || fail "Komodo Stack $s has no stacks/$s folder"
  done
  if [[ $fails -eq $before ]]; then
    pass "placement: $folders stack folders match ${#stack_server[@]} Komodo Stacks, each running on its declared server"
  fi
fi

# 2. Digests, orphans and untracked projects, from the nightly health check's own script.
before=$fails
summary=""
drift_rc=0
drift_out="$(.github/scripts/nas-health-image-drift.sh "$nas")" || drift_rc=$?
while IFS= read -r line; do
  case "$line" in
    "DRIFT "* | "NO SERVICE "* | "ERROR "*) fail "$line" ;;
    "NO REPO COMPOSE "*) fail "$line" ;;
    "SUMMARY "*) summary="${line#SUMMARY  }" ;;
  esac
done <<<"$drift_out"
[[ $drift_rc -eq 0 ]] || fail "nas-health-image-drift.sh exited $drift_rc"
if [[ $fails -eq $before ]]; then pass "digests: ${summary:-no SUMMARY line}"; fi

# 3. Health: the rule verify-healthy.sh deploys by, applied to every container on every server.
before=$fails
checked=0
declare -A containers=()
for id in "${!server_name[@]}"; do
  n="${server_name[$id]}"
  if ! containers["$n"]="$(kapi read/ListDockerContainers "$(jq -nc --arg s "$n" '{server:$s}')")"; then
    fail "server $n: ListDockerContainers failed, health unchecked"
    continue
  fi
  checked=$((checked + 1))
  while IFS= read -r c; do
    [[ -z "$c" ]] || fail "$c (server $n)"
  done < <(jq -r '.[]
      | select((.state != "running" and (((.status // "") | test("^Exited \\(0\\)")) | not))
               or (.state == "running" and ((.status // "") | test("unhealthy"))))
      | "\(.name) is \(.state): \(.status // "")"' <<<"${containers[$n]}")
done
if [[ $fails -eq $before ]]; then
  pass "health: every container on $checked servers is running or cleanly Exited (0), none unhealthy"
fi

# 4. Every proxy_* network caddy's compose defines exists with caddy attached; a down loses them.
if ! want_nets="$(probe yaml2json <stacks/caddy/docker-compose.yml \
    | jq -r '.networks // {} | to_entries[] | (.value.name // .key) | select(startswith("proxy_"))' | sort -u)" \
    || [[ -z "$want_nets" ]]; then
  fail "networks: could not read the proxy_* networks from stacks/caddy/docker-compose.yml"
elif ! have_nets="$(jq -re '.[] | select(.name == "caddy") | .networks[]' <<<"${containers[nas]:-[]}" | sort -u)"; then
  fail "networks: no running caddy container on the nas server"
else
  missing="$(comm -23 <(printf '%s\n' "$want_nets") <(printf '%s\n' "$have_nets") | xargs)"
  if [[ -n "$missing" ]]; then
    fail "networks: caddy is not attached to $missing"
  else
    pass "networks: caddy is attached to all $(grep -c . <<<"$want_nets") proxy_* networks its compose defines"
  fi
fi

# 5. Scripts installed outside the clone, which no pull updates.
before=$fails
if ! copies="$(probe host-copies 2>&1)"; then
  fail "host copies: probe verb host-copies failed ($(grep -m1 refused <<<"$copies" || tr '\n' ' ' <<<"$copies" | head -c 160)); re-install scripts/nas-health-probe.sh on the NAS"
else
  n=0
  while read -r hash file; do
    [[ -n "$file" ]] || continue
    n=$((n + 1))
    want="$(sha256sum "scripts/$file" | cut -d' ' -f1)"
    [[ "$hash" == "$want" ]] || fail "host copies: /mnt/apps/scripts/$file differs from scripts/$file, re-install it by hand"
  done <<<"$copies"
  if [[ $fails -eq $before ]]; then pass "host copies: $n installed script(s) match the repo"; fi
fi

# 6. The ResourceSync: nothing applies an edit to an existing [[...]] entry but a human, so
# pending changes older than one probe cycle were forgotten. Komodo refreshes the view hourly.
SYNC_GRACE_S=$((6 * 3600))
if ! sync="$(kapi read/GetResourceSync '{"sync":"komodo-resources"}')"; then
  fail "sync: Komodo GetResourceSync failed, pending changes unchecked"
else
  read -r last_sha last_ts < <(git log -1 --format='%H %ct' -- komodo/resources.toml)
  age=$(($(date +%s) - last_ts))
  pending_hash="$(jq -r '.info.pending_hash // ""' <<<"$sync")"
  sync_err="$(jq -r '[.info.pending_error // empty, (.info.remote_errors // [])[].contents // empty] | join("; ") | .[0:200]' <<<"$sync")"
  pending="$(jq -r '[.info.resource_updates[]?.target.type] | group_by(.) | map("\(length) \(.[0])") | join(", ")' <<<"$sync")"
  if [[ -n "$sync_err" ]]; then
    fail "sync: komodo-resources cannot compute its pending changes: $sync_err"
  elif ! git merge-base --is-ancestor "$last_sha" "$pending_hash" 2>/dev/null; then
    if ((age > 2 * 3600)); then
      fail "sync: the pending view is at ${pending_hash:-nothing}, older than ${last_sha:0:7}, the last komodo/resources.toml change; Komodo stopped refreshing it"
    else
      say "NOTE  sync: the pending view is not yet at ${last_sha:0:7}, the last komodo/resources.toml change"
    fi
  elif [[ -n "$pending" ]]; then
    if ((age > SYNC_GRACE_S)); then
      fail "sync: komodo-resources has pending changes ($pending), $((age / 3600)) h after ${last_sha:0:7}; read the diff and run the sync (docs/services/komodo.md)"
    else
      say "NOTE  sync: komodo-resources has pending changes ($pending) from ${last_sha:0:7}, $((age / 60)) min ago"
    fi
  else
    pass "sync: komodo-resources has no pending changes at ${pending_hash:0:7}"
  fi
fi

# 7. The deterministic half of the nightly health check: snapshots, scrubs, dumps,
# certs, the on-host clone, the boot guard, the Storage Box.
det_rc=0
det_out="$(.github/scripts/nas-deterministic-checks.sh "$nas")" || det_rc=$?
while IFS= read -r line; do
  [[ -n "$line" && "$line" != RESULT* ]] || continue
  say "$line"
  [[ "$line" != FAIL* ]] || fails=$((fails + 1))
done <<<"$det_out"
[[ $det_rc -eq 0 || $det_rc -eq 1 ]] || fail "nas-deterministic-checks.sh exited $det_rc"

finish
