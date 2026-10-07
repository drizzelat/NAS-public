#!/usr/bin/env bash
# Hourly on the NAS (TrueNAS cron, root): push each periphery's compose file from the repo clone to its
# host and let scripts/periphery-apply.sh recreate it. Docs: docs/runbooks/setup-operations/periphery-auto-apply.md

set -uo pipefail

ROOT="${PERIPHERY_UPDATE_ROOT:-/mnt/apps/scripts/nas}"   # the auto-pulled clone, nas-repo-autopull.md
LOG="${PERIPHERY_UPDATE_LOG:-/var/log/periphery-update.log}"
# Also the NAS periphery's compose dir, and where a failed file's checksum waits so a bad bump is tried once, not hourly.
STATE="${PERIPHERY_UPDATE_STATE:-/mnt/apps/scripts/periphery}"
# "ssh alias|stack folder". The aliases (host, port, one forced-command key each) live in /root/.ssh/config.
TARGETS="
a1-periphery|a1-vps-periphery
micro-periphery|micro-vps-periphery
runner-periphery|runner-vm-periphery
local|nas-periphery
"

exec >>"$LOG" 2>&1
now() { date '+%F %T %Z'; }

MAILTO="$(midclt call mail.config 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("fromemail") or "")' 2>/dev/null || true)"
send_mail() {  # $1 = subject; body on stdin
  [ -n "$MAILTO" ] || { echo "no mail recipient configured, cannot send the alert"; return; }
  SUBJ="$1" TO="$MAILTO" python3 -c '
import os, sys, json, subprocess
payload = json.dumps({"subject": os.environ["SUBJ"], "text": sys.stdin.read(), "to": [os.environ["TO"]]})
subprocess.run(["midclt", "call", "mail.send", payload], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
' 2>/dev/null || true
}

# Core first: a periphery newer than Core can break the transport (komodo.md → Upgrade). Core deploys itself
# from the hourly `deploy-komodo` Procedure, so until it runs the repo's pin, change nothing.
pin() { sed -nE 's#^[[:space:]]*image:[[:space:]]*(ghcr\.io/moghtech/komodo-core:[^[:space:]#]+).*#\1#p' "$1" | head -n 1; }
want_core=$(pin "$ROOT/stacks/komodo/docker-compose.yml")
have_core=$(docker inspect komodo-core --format '{{.Config.Image}}' 2>/dev/null || true)
if [ -z "$want_core" ] || [ -z "$have_core" ]; then
  echo "$(now) ERROR: cannot read the Core pin (repo '${want_core:-?}', running '${have_core:-?}')"
  exit 1
fi
if [ "$have_core" != "$want_core" ]; then
  echo "$(now) Core runs $have_core, the repo pins $want_core: peripheries wait for Core"
  exit 0
fi

problems=""
for t in $TARGETS; do
  alias=${t%%|*}; stack=${t##*|}
  file="$ROOT/stacks/$stack/docker-compose.yml"
  [ -r "$file" ] || { problems="$problems$stack: $file is missing\n"; continue; }
  sum=$(sha256sum <"$file" | cut -d' ' -f1)
  if [ "$(cat "$STATE/failed-$stack" 2>/dev/null)" = "$sum" ]; then
    echo "$(now) $stack: this compose file failed before and was rolled back, not retrying (edit it, or rm $STATE/failed-$stack)"
    continue
  fi
  if [ "$alias" = local ]; then
    out=$(PERIPHERY_DIR="$STATE" "$ROOT/scripts/periphery-apply.sh" <"$file" 2>&1); rc=$?
  else
    out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$alias" <"$file" 2>&1); rc=$?
  fi
  # A run that changed nothing is not worth a log line an hour.
  if [ "$rc" != 0 ] || ! grep -qx 'periphery: current' <<<"$out"; then
    echo "$(now) $stack (rc=$rc): $(tr '\n' ' ' <<<"$out")"
  fi
  if [ "$rc" = 0 ]; then
    rm -f "$STATE/failed-$stack"
  else
    # Only an apply that ran and failed (1, 2) latches; ssh's 255 is an unreachable host, retried next hour.
    case $rc in 1|2) mkdir -p "$STATE" && printf '%s\n' "$sum" >"$STATE/failed-$stack" ;; esac
    problems="$problems$stack (rc=$rc): $(tail -n 3 <<<"$out" | tr '\n' ' ')\n"
  fi
done

if [ -n "$problems" ]; then
  printf '%b' "$problems" | send_mail "periphery-update failed on $(hostname)"
  exit 1
fi
