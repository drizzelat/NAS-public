#!/usr/bin/env bash
# F13 adoption pre-flight: `capture <stack>` before a Komodo deploy, `verify <stack>` after (exit 1 = failed).
# Workstation-only, from the repo root, read-only (`docker ps -a` over SSH). Verdicts: komodo-migration.md §9.
set -euo pipefail

usage() { echo "usage: $0 capture|verify <stack>" >&2; exit 2; }
[ $# -eq 2 ] || usage
mode="$1" stack="$2"
case "$mode" in capture|verify) ;; *) usage ;; esac
case "$stack" in *[!a-z0-9_-]*|'') echo "bad stack name: $stack" >&2; exit 2 ;; esac

host="${ADOPTION_HOST:-}"  # nas|micro-vps|a1-vps; default routes by name prefix like fire-webhooks.sh
if [ -z "$host" ]; then
  case "$stack" in
    a1-vps-*)    host=a1-vps ;;
    micro-vps-*) host=micro-vps ;;
    *)           host=nas ;;
  esac
fi
case "$host" in
  nas)       ssh_cmd=(ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111) ;;
  micro-vps) ssh_cmd=(ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10) ;;
  a1-vps)    ssh_cmd=(ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20) ;;
  *) echo "unknown host: $host" >&2; exit 2 ;;
esac

state_dir="${ADOPTION_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nas-adoption}"
snapshot="$state_dir/$host-$stack.tsv"

# id, name, project, service, working_dir, state. Every container on the host, not just this
# project: a failed adoption shows up as a container in some *other* project.
list_containers() {
  "${ssh_cmd[@]}" -o ConnectTimeout=10 \
    "sudo -n docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.State}}'" \
    | sort
}

in_project() { awk -F'\t' -v p="$stack" '$3 == p' "$1"; }

if [ "$mode" = capture ]; then
  mkdir -p "$state_dir"
  list_containers > "$snapshot.tmp"
  mv "$snapshot.tmp" "$snapshot"
  n="$(in_project "$snapshot" | wc -l)"
  echo "captured $host/$stack: $n container(s) in project $stack -> $snapshot"
  in_project "$snapshot" | awk -F'\t' '{printf "  %s  %-40s %-20s %s\n", substr($1,1,12), $2, $4, $6}'
  [ "$n" -gt 0 ] || echo "WARN  no containers in project $stack. Expected only for a stack whose services are all stopped"
  exit 0
fi

[ -s "$snapshot" ] || { echo "no snapshot at $snapshot: run capture before deploying" >&2; exit 2; }
after="$(mktemp)"
trap 'rm -f "$after"' EXIT
list_containers > "$after"

fail=0 warn=0
say()  { echo "$*"; }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
soft() { echo "WARN  $*"; warn=$((warn + 1)); }

# Per service, keyed by container name: names and project must survive, IDs may change once.
declare -A before_id=() before_state=() after_id=() after_state=()
while IFS=$'\t' read -r id name _ _ _ st; do before_id["$name"]="$id"; before_state["$name"]="$st"; done < <(in_project "$snapshot")
while IFS=$'\t' read -r id name _ _ _ st; do after_id["$name"]="$id"; after_state["$name"]="$st"; done < <(in_project "$after")

changed=0 same=0
for name in "${!before_id[@]}"; do
  if [ -z "${after_id[$name]:-}" ]; then
    bad "$name was in project $stack before the deploy and is gone"
    continue
  fi
  if [ "${before_id[$name]}" = "${after_id[$name]}" ]; then same=$((same + 1)); else changed=$((changed + 1)); fi
  if [ "${before_state[$name]}" = running ] && [ "${after_state[$name]}" != running ]; then
    bad "$name was running before and is ${after_state[$name]} now"
  fi
done
for name in "${!after_id[@]}"; do
  [ -n "${before_id[$name]:-}" ] || soft "$name is new in project $stack: a service added in this deploy, or a rename"
done

# The F13 split brain: a container that did not exist before, outside the project, that belongs
# to this stack by its working directory or its name. Komodo reports success when this happens.
while IFS=$'\t' read -r id name project _ wd _; do
  grep -q "^$id"$'\t' "$snapshot" && continue
  [ "$project" = "$stack" ] && continue
  if [[ "$wd" == */"$stack" || "$name" =~ (^|[-_])"$stack"([-_]|$) ]]; then
    bad "new container $name in project '${project:-none}' (working dir ${wd:-none}): F13 duplicate. Roll back per §10 now"
  else
    say "NOTE  unrelated new container on $host: $name (project ${project:-none})"
  fi
done < "$after"

total="${#before_id[@]}"
if [ "$fail" -gt 0 ]; then
  say "RESULT  $host/$stack: FAILED adoption, $fail failure(s)"
  exit 1
fi
if [ "$total" -eq 0 ]; then
  say "RESULT  $host/$stack: nothing to compare, the project had no containers before"
elif [ "$changed" -eq "$total" ]; then
  say "RESULT  $host/$stack: ADOPTED, all $total container(s) recreated once under the same names (F15)"
elif [ "$same" -eq "$total" ]; then
  say "RESULT  $host/$stack: NO CHANGE, no container was recreated. Already adopted, or the deploy did nothing"
else
  soft "only $changed of $total container(s) were recreated. F15 expects all of them on an adoption"
  say "RESULT  $host/$stack: PARTIAL, check the services above"
fi
[ "$warn" -eq 0 ] || say "($warn warning(s))"
