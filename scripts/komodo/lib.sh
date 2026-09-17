# shellcheck shell=bash
# Komodo API helpers for the deploy scripts and secrets.sh. Source it; it runs nothing on its own.
# Env: KOMODO_URL, KOMODO_API_KEY, KOMODO_API_SECRET; optional KOMODO_RESOLVE (curl --resolve
# host:port:addr), KOMODO_DRY_RUN=true. Docs: docs/services/komodo.md

KOMODO_OWNED_FILE="${KOMODO_OWNED_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/komodo/owned-stacks}"

komodo_err() {  # GitHub annotation in Actions, plain text elsewhere
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
}

komodo_owned() {  # komodo_owned -> the names in komodo/owned-stacks, one per line
  [ -f "$KOMODO_OWNED_FILE" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$KOMODO_OWNED_FILE" | sed '/^$/d'
}

is_komodo_owned() {  # is_komodo_owned <stack>
  komodo_owned | grep -qxF -- "$1"
}

# kapi <read|write|execute>/<Type> [json] -> response body on stdout.
# The body goes in on stdin and the credentials as a header file, so neither reaches argv.
kapi() {
  local path="$1" body="${2:-"{}"}" out code resolve=()
  if [ -z "${KOMODO_URL:-}" ] || [ -z "${KOMODO_API_KEY:-}" ] || [ -z "${KOMODO_API_SECRET:-}" ]; then
    komodo_err "KOMODO_URL, KOMODO_API_KEY and KOMODO_API_SECRET must all be set"; return 2
  fi
  [ -z "${KOMODO_RESOLVE:-}" ] || resolve=(--resolve "$KOMODO_RESOLVE")
  out=$(mktemp)
  code=$(printf '%s' "$body" | curl -sS --max-time 60 "${resolve[@]}" -o "$out" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -H @<(printf 'X-Api-Key: %s\nX-Api-Secret: %s\n' "$KOMODO_API_KEY" "$KOMODO_API_SECRET") \
    --data-binary @- "$KOMODO_URL/$path") || code=000
  if [ "$code" != 200 ]; then
    # Komodo errors are {"error": ..., "trace": [...]}. Print the message only, never the request.
    komodo_err "komodo $path: HTTP $code: $(jq -r '.error // empty' "$out" 2>/dev/null | head -c 300)"
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# komodo_deploy <stack> -> 0 deployed (or dry run), 1 the deploy ran and failed, 3 it never started.
komodo_deploy() {
  local stack="$1" id q prev rec upd status="" i
  id=$(kapi read/GetStack "$(jq -nc --arg s "$stack" '{stack:$s}')" | jq -r '._id."$oid" // empty') || return 3
  [ -n "$id" ] || { komodo_err "no Komodo Stack named $stack"; return 3; }
  # An execute sent while the stack is busy is dropped, with only a Core log line to show for it
  # (komodo-migration.md F16). Wait for the stack to go idle first.
  for i in $(seq 1 120); do
    status=$(kapi read/GetStackActionState "$(jq -nc --arg s "$id" '{stack:$s}')" | jq -r '[.[]] | any') || return 3
    [ "$status" = false ] && break
    [ "$i" = 120 ] && { komodo_err "$stack is still busy in Komodo after 10 min, not deployed"; return 3; }
    sleep 5
  done
  q=$(jq -nc --arg id "$id" '{query:{"target.type":"Stack","target.id":$id,operation:"DeployStack"}}')
  prev=$(kapi read/ListUpdates "$q" | jq -r '.updates[0].id // ""') || return 3
  if [ "${KOMODO_DRY_RUN:-false}" = true ]; then
    echo "dry run: would DeployStack $stack (Komodo stack $id, idle, last deploy record ${prev:-none})"
    return 0
  fi
  kapi execute/DeployStack "$(jq -nc --arg s "$id" '{stack:$s}')" >/dev/null || return 3
  # The execute response is an InProgress stub with no id, so find the record it wrote.
  rec=""
  for i in $(seq 1 12); do
    rec=$(kapi read/ListUpdates "$q" | jq -r --arg p "$prev" '.updates[0].id // "" | select(. != $p)') || rec=""
    [ -n "$rec" ] && break
    sleep 5
  done
  [ -n "$rec" ] || { komodo_err "Komodo took DeployStack for $stack but wrote no record within 60s (dropped as busy? F16)"; return 3; }
  echo "Komodo is deploying $stack (update $rec)"
  for i in $(seq 1 "${KOMODO_DEPLOY_POLLS:-360}"); do  # 30 min at 5 s
    upd=$(kapi read/GetUpdate "$(jq -nc --arg r "$rec" '{id:$r}')") || { sleep 5; continue; }
    status=$(printf '%s' "$upd" | jq -r '.status')
    if [ "$status" = Complete ]; then
      if [ "$(printf '%s' "$upd" | jq -r '.success')" = true ]; then
        echo "OK: Komodo deployed $stack"; return 0
      fi
      komodo_err "Komodo DeployStack failed for $stack (update $rec)"
      # Failed stages only. Compose Config's stdout is the interpolated file, so it is never printed whole.
      printf '%s' "$upd" | jq -r '.logs[] | select(.success | not) | "  [\(.stage)] \((.stderr + " " + .stdout) | .[-800:])"'
      return 1
    fi
    sleep 5
  done
  komodo_err "Komodo DeployStack for $stack is still $status after 30 min (update $rec)"
  return 1
}

# komodo_stack_exists <stack> -> 0 when Komodo has a Stack of that name. limit 0: lists page at 50 (F32).
komodo_stack_exists() {
  local n
  n=$(kapi read/ListStacks "$(jq -nc --arg s "$1" '{query:{names:[$s]},limit:0}')" | jq 'length') || return 2
  [ "$n" -gt 0 ]
}

# komodo_sync <Stack|Procedure> <name> -> 0 when a RunSync filtered to that one resource succeeded.
komodo_sync() {
  local type="$1" name="$2" sid q prev rec upd i
  sid=$(kapi read/GetResourceSync '{"sync":"komodo-resources"}' | jq -r '._id."$oid" // empty') || return 1
  q=$(jq -nc --arg id "$sid" '{query:{"target.type":"ResourceSync","target.id":$id,operation:"RunSync"}}')
  prev=$(kapi read/ListUpdates "$q" | jq -r '.updates[0].id // ""') || return 1
  kapi execute/RunSync "$(jq -nc --arg t "$type" --arg n "$name" '{sync:"komodo-resources",resource_type:$t,resources:[$n]}')" >/dev/null || return 1
  rec=""
  for i in $(seq 1 36); do  # 3 min at 5 s
    upd=$(kapi read/ListUpdates "$q" | jq -c --arg p "$prev" '.updates[0] // {} | select(.id != $p and .status == "Complete")') || upd=""
    rec=$(printf '%s' "$upd" | jq -r '.id // empty')
    [ -n "$rec" ] && break
    sleep 5
  done
  [ -n "$rec" ] || { komodo_err "RunSync for $type $name wrote no completed record within 3 min (busy? F16)"; return 1; }
  upd=$(kapi read/GetUpdate "$(jq -nc --arg r "$rec" '{id:$r}')") || return 1
  if [ "$(printf '%s' "$upd" | jq -r '.success')" != true ]; then
    komodo_err "RunSync for $type $name failed (update $rec)"
    printf '%s' "$upd" | jq -r '.logs[] | select(.success | not) | "  [\(.stage)] \((.stderr + " " + .stdout) | .[-800:])"'
    return 1
  fi
  echo "synced $type $name from komodo/resources.toml (update $rec)"
}

# komodo_create <stack> -> creates a new owned stack's Stack and refreshes reconcile-owned, from the
# repo's komodo/resources.toml, through syncs filtered to them (komodo-migration.md F29). No deploy.
komodo_create() {
  local stack="$1" toml vars have missing="" v
  toml="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/komodo/resources.toml"
  if ! awk -v s="$stack" '/^\[\[/ { st = ($0 == "[[stack]]") } st && $0 == "name = \"" s "\"" { f = 1 } END { exit !f }' "$toml"; then
    komodo_err "'$stack' is in komodo/owned-stacks but has no [[stack]] entry in komodo/resources.toml"; return 1
  fi
  # The Variables its environment names must exist before the Stack deploys, or ${VAR} lands empty.
  vars=$(awk -v s="$stack" '/^\[\[/ { st = ($0 == "[[stack]]"); f = 0 } st && $0 == "name = \"" s "\"" { f = 1 } f' "$toml" \
    | grep -oE '\[\[[A-Z0-9_]+\]\]' | tr -d '[]' | sort -u)
  if [ -n "$vars" ]; then
    have=$(kapi read/ListVariables '{}' | jq -r '.[].name') || return 1
    for v in $vars; do printf '%s\n' "$have" | grep -qxF "$v" || missing="$missing $v"; done
    if [ -n "$missing" ]; then
      komodo_err "'$stack' needs Komodo Variables that do not exist:$missing. Run 'scripts/secrets.sh komodo-vars $stack' from the workstation, then re-run deploy-stacks for it"
      return 1
    fi
  fi
  if [ "${KOMODO_DRY_RUN:-false}" = true ]; then
    echo "dry run: would create Stack $stack and refresh reconcile-owned through filtered syncs"; return 0
  fi
  komodo_sync Stack "$stack" || return 1
  komodo_sync Procedure reconcile-owned || return 1
  komodo_stack_exists "$stack" || { komodo_err "the sync ran, but Komodo still has no Stack named $stack"; return 1; }
}

# komodo_check_commit <stack> <sha> -> 0 when the Stack's deployed commit is <sha> or a descendant.
# A pull can be 5 s stale and a re-cloned repo can strand a mount (komodo-migration.md F28).
komodo_check_commit() {
  local stack="$1" want="$2" got
  got=$(kapi read/GetStack "$(jq -nc --arg s "$stack" '{stack:$s}')" | jq -r '.info.deployed_hash // empty') || return 1
  [ -n "$got" ] || { komodo_err "$stack: Komodo reports no deployed commit"; return 1; }
  git cat-file -e "$got^{commit}" 2>/dev/null || git fetch --quiet origin main || true
  if git merge-base --is-ancestor "$want" "$got" 2>/dev/null; then
    echo "$stack: Komodo deployed $got, at or after $want"; return 0
  fi
  komodo_err "$stack: Komodo deployed $got, which does not contain $want (a stale pull? komodo-migration.md F28)"
  return 1
}
