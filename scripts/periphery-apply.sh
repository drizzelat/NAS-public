#!/usr/bin/env bash
# Apply a komodo-periphery compose file (on stdin) to THIS host, roll back if the new container is
# not healthy. Runs as root: the forced command on the three remote hosts, a direct call on the NAS.
# Docs: docs/runbooks/setup-operations/periphery-auto-apply.md
#
# Exit 0 = already current or applied, 1 = failed and rolled back, 2 = failed with nothing to roll back to.

set -uo pipefail

DIR="${PERIPHERY_DIR:-/home/ubuntu/periphery}"   # project name `periphery` comes from -p, not from this name
FILE="$DIR/docker-compose.yml"
NAME=komodo-periphery
KEEP=5

exec 9>"${PERIPHERY_LOCK:-/run/periphery-apply.lock}" || { echo "periphery: cannot open the lock" >&2; exit 2; }
flock -n 9 || { echo "periphery: another apply is running, skipping" >&2; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/new.yml"
[ -s "$work/new.yml" ] || { echo "periphery: empty compose file on stdin" >&2; exit 2; }

compose() { docker compose -p periphery "$@"; }
# The label and `config --hash` come from the same compose binary here, so they are comparable.
hash_of() { compose -f "$1" config --hash '*' | awk '$1 == "periphery" { print $2 }'; }

compose -f "$work/new.yml" config --quiet || { echo "periphery: the new compose file does not validate" >&2; exit 2; }
want=$(hash_of "$work/new.yml")
[ -n "$want" ] || { echo "periphery: could not hash the new compose file" >&2; exit 2; }
have=$(docker inspect "$NAME" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' 2>/dev/null || true)
if [ "$have" = "$want" ]; then
  echo "periphery: current"
  exit 0
fi
prev=$(docker inspect "$NAME" --format '{{.Config.Image}}' 2>/dev/null || true)

# host:port the periphery listens on, from the config itself, so the check needs no per-host setting.
listen=$(compose -f "$work/new.yml" config --format json | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]["periphery"]
ip, port = (s.get("environment") or {}).get("PERIPHERY_BIND_IP") or "127.0.0.1", 8120
if s.get("ports"):
    ip, port = s["ports"][0].get("host_ip") or ip, int(s["ports"][0]["published"])
print(f"{ip} {port}")') || { echo "periphery: could not read the listen address" >&2; exit 2; }
read -r ip port <<<"$listen"

healthy() {   # running, not restarting, and the port answers, twice 10 s apart
  local i
  for i in 1 2; do
    [ "$(docker inspect "$NAME" --format '{{.State.Running}} {{.RestartCount}}' 2>/dev/null)" = "true 0" ] || return 1
    timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null || return 1
    [ "$i" = 2 ] || sleep "${PERIPHERY_GAP:-10}"
  done
}
wait_healthy() {
  local waited=0
  while [ "$waited" -lt "${PERIPHERY_WAIT:-90}" ]; do
    healthy && return 0
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

mkdir -p "$DIR"
old=""
if [ -f "$FILE" ]; then
  old="$FILE.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$FILE" "$old"
fi
cp "$work/new.yml" "$FILE"
# shellcheck disable=SC2012  # backup names are ours, no odd characters
ls -1t "$FILE".bak-* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f --

restore() {
  [ -n "$old" ] || return 1
  cp "$old" "$FILE"
  compose -f "$FILE" up -d
}

if ! compose -f "$FILE" pull; then
  echo "periphery: pull failed, container untouched" >&2
  [ -z "$old" ] || cp "$old" "$FILE"
  exit 1
fi
compose -f "$FILE" up -d
if wait_healthy; then
  echo "periphery: applied ${prev:-(none)} -> $(docker inspect "$NAME" --format '{{.Config.Image}}')"
  exit 0
fi

echo "periphery: the new container is not healthy, rolling back to ${prev:-(nothing)}" >&2
if restore && wait_healthy; then
  echo "periphery: rolled back to ${prev:-the previous file}" >&2
  exit 1
fi
echo "periphery: ROLLBACK FAILED, the periphery needs hand repair" >&2
exit 2
