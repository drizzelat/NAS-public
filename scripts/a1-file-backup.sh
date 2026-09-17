#!/bin/sh
# Mirror the A1's non-database files onto the NAS over the tailnet, into a dataset the
# 03:00 cloud-sync chain already carries. Docs: docs/runbooks/backup-restore/a1-matrix-backup.md

set -eu

# "ssh-alias|destination". Each alias is defined in /root/.ssh/config with its own key,
# which the A1 pins to one `rrsync -ro <root>` forced command — so the alias IS the scope.
SYNCS="
a1-files|/mnt/apps/a1-matrix/media_store
a1-kuma|/mnt/apps/a1-matrix/kuma
"

LOCK=/var/run/a1-file-backup.lock

# Optional Uptime-Kuma push monitor, pinged on success; a late ping catches the job
# not running at all. Host file, not the repo — no token committed.
PUSH_URL_FILE="/root/.config/a1-file-backup-kuma-push.url"

# Failure email (mirrors pg-dump-backup.sh); TrueNAS's own cron mail goes nowhere.
MAILTO="$(midclt call mail.config 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("fromemail") or "")' 2>/dev/null || true)"

send_mail() {  # $1 = subject; body on stdin
  [ -n "$MAILTO" ] || { echo "no mail recipient configured — cannot send alert" >&2; return; }
  SUBJ="$1" TO="$MAILTO" python3 -c '
import os, sys, json, subprocess
payload = json.dumps({"subject": os.environ["SUBJ"],
                      "text": sys.stdin.read(),
                      "to": [os.environ["TO"]]})
subprocess.run(["midclt", "call", "mail.send", payload],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
' 2>/dev/null || true
}

PROBLEMS=""
problem() {
  echo "$1" >&2
  PROBLEMS="${PROBLEMS}${1}\n"
}

# Single instance: the media sync takes ~an hour on a cold start, and two --delete
# mirrors onto one destination fight over the same tree.
exec 9>"$LOCK" 2>/dev/null || { echo "cannot open lock $LOCK" >&2; exit 1; }
if command -v flock >/dev/null 2>&1; then
  # A held lock at the next nightly run means the previous one has been going 24h.
  flock -n 9 || problem "another sync still holds $LOCK — the previous run never finished"
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

[ -n "$PROBLEMS" ] || while IFS='|' read -r alias dest; do
  [ -n "$alias" ] || continue

  mkdir -p "$dest"

  # --delete keeps this a true mirror; deletion history comes from the apps snapshot
  # task (4-hourly, 3 days) and from the offsite copy, not from an ever-growing dir.
  rc=0
  rsync -a --delete --partial --timeout=600 \
    -e "ssh -o BatchMode=yes" --stats "$alias:/" "$dest/" > "$LOG" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    problem "ERROR $alias -> $dest: rsync exited $rc — $(tail -3 "$LOG" | tr '\n' ' ')"
    continue
  fi

  # An empty mirror means the source vanished or the restriction broke — never a good sync.
  if [ -z "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    problem "ERROR $alias -> $dest: rsync reported success but the destination is empty"
    continue
  fi

  echo "$alias -> $dest: $(grep -E '^Number of files:' "$LOG" || echo 'synced')"
done <<EOF
$SYNCS
EOF

if [ -n "$PROBLEMS" ]; then
  printf 'A1 file sync had failures on %s at %s:\n\n%b\nMatrix media / the external watchdog DB may exist in only one copy until this is fixed.\n' \
    "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$PROBLEMS" \
    | send_mail "[NAS] A1 file sync FAILED"
  exit 1
fi

if [ -r "$PUSH_URL_FILE" ]; then
  url="$(cat "$PUSH_URL_FILE")"
  [ -n "$url" ] && curl -fsS -m 15 "$url" >/dev/null 2>&1 || true
fi

echo "A1 file sync OK."
