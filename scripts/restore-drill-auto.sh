#!/bin/sh
# Monthly proof that the OFFSITE copy restores: pull apps/kuma back from Hetzner into a
# scratch path, decrypt it, integrity-check the SQLite DB, compare the file count with the
# live dataset, delete the scratch copy. Docs: docs/runbooks/backup-restore/restore-drill.md

set -u

LOG=/var/log/restore-drill-auto.log
LOCK=/var/run/restore-drill-auto.lock
SCRATCH=/mnt/apps/restore-drill
DATASET=apps/kuma
REMOTE_FOLDER=/backup/apps/kuma
DB=kuma.db
POLL=15
# The PULL task this script drives. Created once by hand; see the runbook.
TASK_MARKER="restore-drill PULL"
PUSH_URL_FILE=/root/.config/restore-drill-kuma-push.url

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
err() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG" >&2; }

MAILTO="$(midclt call mail.config 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("fromemail") or "")' 2>/dev/null)"

send_mail() {  # $1 = subject; body on stdin
  [ -n "$MAILTO" ] || { err "no mail recipient configured — cannot send alert"; return; }
  SUBJ="$1" TO="$MAILTO" python3 -c '
import os, sys, json, subprocess
payload = json.dumps({"subject": os.environ["SUBJ"],
                      "text": sys.stdin.read(),
                      "to": [os.environ["TO"]]})
subprocess.run(["midclt", "call", "mail.send", payload],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
' 2>/dev/null || true
}

fatal() {  # $1 = message
  err "FAIL: $1"
  printf 'The automated restore drill FAILED on %s at %s:\n\n  %s\n\nThe offsite copy is NOT proven to restore. Log: %s\nManual drill: docs/runbooks/backup-restore/restore-drill.md\n' \
    "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$LOG" \
    | send_mail "[NAS] Restore drill FAILED"
  cleanup
  exit 1
}

cleanup() {
  # Never let an empty or short SCRATCH turn this into rm -rf /.
  case "$SCRATCH" in
    /mnt/apps/restore-drill*) rm -rf "$SCRATCH" 2>/dev/null || true ;;
    *) err "refusing to delete unexpected scratch path $SCRATCH" ;;
  esac
}

# First Sunday only: the cron fires every Sunday because cron ORs day-of-month with
# day-of-week. RESTORE_DRILL_FORCE=1 runs it any day, for a hand test.
if [ "${RESTORE_DRILL_FORCE:-0}" != "1" ] && [ "$(date +%-d)" -gt 7 ]; then
  exit 0
fi

exec 9>"$LOCK" 2>/dev/null || { err "FATAL: cannot open lock $LOCK"; exit 1; }
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { err "FATAL: another drill run holds the lock; aborting"; exit 1; }
fi

command -v sqlite3 >/dev/null 2>&1 || fatal "sqlite3 is not installed on this host"

log "drill start ($DATASET from $REMOTE_FOLDER)"

TASK_ID="$(midclt call cloudsync.query '[["direction","=","PULL"]]' \
  '{"select":["id","description"]}' 2>/dev/null \
  | MARKER="$TASK_MARKER" python3 -c '
import os, sys, json
marker = os.environ["MARKER"]
hits = [t for t in json.load(sys.stdin) if marker in (t.get("description") or "")]
if len(hits) != 1:
    sys.exit(2)
print(hits[0]["id"])
' 2>/dev/null)" \
  || fatal "no single PULL task whose description contains \"$TASK_MARKER\" — create it once (see the runbook)"

# Re-point it at this run's scratch path. The credential and the crypt password/salt stay
# in the middleware: this never reads them.
payload="$(DEST="$SCRATCH" python3 -c '
import os, json
print(json.dumps({"path": os.environ["DEST"]}))
')"
midclt call cloudsync.update "$TASK_ID" "$payload" >/dev/null 2>&1 \
  || fatal "cloudsync.update rejected the scratch path"

cleanup
mkdir -p "$SCRATCH" || fatal "cannot create $SCRATCH"

jid="$(midclt call cloudsync.sync "$TASK_ID" 2>/dev/null)"
[ -n "$jid" ] || fatal "could not start the PULL job"

while :; do
  state="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["state"]}' \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["state"] if d else "GONE")')"
  case "$state" in
    SUCCESS) break ;;
    FAILED|ABORTED)
      reason="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["error"]}' \
        | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d[0].get("error") or "").replace(chr(10)," ")[:300] if d else "")')"
      fatal "PULL job $state: $reason"
      ;;
    GONE) fatal "PULL job $jid vanished" ;;
    *) sleep "$POLL" ;;
  esac
done

[ -f "$SCRATCH/$DB" ] || fatal "$DB is not in the restored copy of $REMOTE_FOLDER"

# A wrong crypt salt restores garbage that still looks like files, so the DB has to open.
check="$(sqlite3 "$SCRATCH/$DB" 'PRAGMA integrity_check;' 2>&1)"
[ "$check" = "ok" ] || fatal "PRAGMA integrity_check on the restored $DB says: $check"

restored="$(find "$SCRATCH" -type f | wc -l)"
live="$(find "/mnt/$DATASET" -type f | wc -l)"
[ "$restored" -gt 0 ] || fatal "the restored copy holds no files at all"
# The live dataset moves while the backup is a snapshot, so this is a sanity band, not equality.
if [ "$((restored * 2))" -lt "$live" ]; then
  fatal "restored $restored files, live /mnt/$DATASET has $live — the offsite copy is short"
fi

log "OK    restored $restored files (live $live), $DB integrity_check ok"
cleanup

if [ -r "$PUSH_URL_FILE" ]; then
  url="$(cat "$PUSH_URL_FILE")"
  [ -n "$url" ] && curl -fsS -m 15 "$url" >/dev/null 2>&1 || true
fi

log "drill done"
exit 0
