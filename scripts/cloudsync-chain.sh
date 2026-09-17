#!/bin/sh
# Drive ONE template Cloud Sync task across every backed-up leaf dataset, SERIALLY
# (the box caps connections). Keep the lists below in sync with docs/runbooks/backup-restore/backup.md.

set -u

LOG=/var/log/cloudsync-chain.log
POLL=15                       # seconds between job-state polls
LOCK=/var/run/cloudsync-chain.lock

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
err() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG" >&2; }

# TrueNAS emails these to an unset admin address and blames the template task,
# not the dataset — so send our own. Recipient = the configured From address.
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

# FATAL: the whole run could not proceed (no template, middleware down, etc.).
fatal() {  # $1 = message
  err "FATAL: $1"
  printf 'cloudsync-chain ABORTED on %s at %s:\n\n  %s\n\nNothing was backed up this run. Log: %s\n' \
    "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$LOG" \
    | send_mail "[NAS] Cloud Sync backup ABORTED"
  exit 1
}

# Single instance: the template is a shared, mutated object, so two runs would
# stomp each other's path/folder mid-sync.
exec 9>"$LOCK" 2>/dev/null || { err "FATAL: cannot open lock $LOCK"; exit 1; }
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { err "FATAL: another chain run holds the lock; aborting"; exit 1; }
fi

# Locate the single template task (the only snapshot==true task).
TEMPLATE_JSON="$(midclt call cloudsync.query '[["snapshot","=",true]]' \
  '{"select":["id","description","attributes"]}')" \
  || fatal "cloudsync.query failed (is the middleware up?)"

TEMPLATE_ID="$(printf '%s' "$TEMPLATE_JSON" | python3 -c '
import sys, json
t = json.load(sys.stdin)
if len(t) != 1:
    sys.stderr.write("expected exactly 1 snapshot:true task, got %d\n" % len(t))
    sys.exit(2)
print(t[0]["id"])
')" || fatal "need exactly one snapshot:true template task (found 0 or more than 1)"

# Preserve the template attributes verbatim; only `folder` is swapped per dataset.
BASE_ATTRS="$(printf '%s' "$TEMPLATE_JSON" \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)[0]["attributes"]))')"

# Return the template to an obvious idle state on the way out, even on interrupt.
idle() { midclt call cloudsync.update "$TEMPLATE_ID" \
  '{"description":"Backup chain template (idle)"}' >/dev/null 2>&1 || true; }
trap idle EXIT

# Build the dataset list live via midclt (no PATH/sudo dependency on zfs).
# FILESYSTEM only; snapshot mode needs leaves, so parents are filtered out.
DATASETS="$(midclt call pool.dataset.query '[["type","=","FILESYSTEM"]]' '{"select":["name"]}' \
  | python3 -c '
import sys, json
names = [d["name"] for d in json.load(sys.stdin)]
nameset = set(names)

def is_leaf(n):
    p = n + "/"
    return not any(o != n and o.startswith(p) for o in nameset)

DATA_INCLUDE = ("data/immich", "data/paperless", "data/smb_share")
APPS_EXCLUDE = ("apps/.system", "apps/.ix-virt", "apps/ix-apps", "apps/tailscale")

def under(n, prefixes):
    return any(n == p or n.startswith(p + "/") for p in prefixes)

def keep(n):
    if "/" not in n:                 # pool root, never a backup target
        return False
    pool = n.split("/", 1)[0]
    if pool == "data":
        return under(n, DATA_INCLUDE)
    if pool == "apps":
        return not under(n, APPS_EXCLUDE)
    return False

data = sorted(n for n in names if n.startswith("data/") and is_leaf(n) and keep(n))
apps = sorted(n for n in names if n.startswith("apps/") and is_leaf(n) and keep(n))
for n in data + apps:
    print(n)
')" || fatal "could not build dataset list from pool.dataset.query"

if [ -z "$DATASETS" ]; then
  fatal "no leaf datasets matched — nothing to back up"
fi

# Loop from a file (redirect, not a pipe) so `fail` survives in this shell.
TMP="$(mktemp)"
FAILS="$(mktemp)"
trap 'idle; rm -f "$TMP" "$FAILS"' EXIT
printf '%s\n' "$DATASETS" > "$TMP"

# Record a dataset failure: log it, flag the run, queue it for the email.
record_fail() {  # $1 = dataset, $2 = reason
  err "FAIL  $1: $2"
  fail=1
  printf '  - %s\n      %s\n' "$1" "$2" >> "$FAILS"
}

# Sweep temp snapshots leaked by interrupted runs — nothing else cleans them up.
# The name carries its own timestamp, so age costs no extra property read.
SWEEP_DAYS=2

leaked="$(midclt call zfs.snapshot.query '[]' '{"select":["name"]}' 2>/dev/null \
  | SWEEP_DAYS="$SWEEP_DAYS" python3 -c '
import sys, json, os, re, datetime
cutoff = datetime.datetime.now() - datetime.timedelta(days=int(os.environ["SWEEP_DAYS"]))
pat = re.compile(r"@cloud_sync-\d+-(\d{14})$")
for s in json.load(sys.stdin):
    m = pat.search(s["name"])
    if not m:
        continue
    try:
        ts = datetime.datetime.strptime(m.group(1), "%Y%m%d%H%M%S")
    except ValueError:
        continue          # unparseable stamp: leave it for a human
    if ts < cutoff:
        print(s["name"])
' 2>/dev/null)" || leaked=""

if [ -n "$leaked" ]; then
  nleak=0
  for snap in $leaked; do
    if midclt call zfs.snapshot.delete "$snap" >/dev/null 2>&1; then
      log "SWEEP destroyed leaked temp snapshot $snap"
      nleak=$((nleak + 1))
    else
      err "SWEEP could not destroy $snap"
    fi
  done
  log "swept $nleak leaked cloud_sync snapshot(s) older than ${SWEEP_DAYS}d"
fi

log "chain start (template id=$TEMPLATE_ID, $(wc -l < "$TMP") datasets)"
fail=0

while IFS= read -r ds; do
  [ -z "$ds" ] && continue

  # Rewrite the template for this dataset. Clearing `exclude` every iteration is
  # essential, or the jellyfin cache filter leaks forward to the next dataset.
  payload="$(DS="$ds" BASE_ATTRS="$BASE_ATTRS" python3 -c '
import os, json
ds = os.environ["DS"]
attrs = json.loads(os.environ["BASE_ATTRS"])
attrs["folder"] = "/backup/" + ds
exclude = ["/cache/**"] if ds.endswith("/mediaserver/config/jellyfin") else []
print(json.dumps({
    "path": "/mnt/" + ds,
    "attributes": attrs,
    "exclude": exclude,
    "description": "chain: " + ds,
}))
')"

  if ! midclt call cloudsync.update "$TEMPLATE_ID" "$payload" >/dev/null; then
    record_fail "$ds" "cloudsync.update rejected the payload"
    continue
  fi

  log "START $ds"
  jid="$(midclt call cloudsync.sync "$TEMPLATE_ID" 2>/dev/null)"
  if [ -z "$jid" ]; then
    record_fail "$ds" "could not start sync"
    continue
  fi

  # Poll until the job is terminal before touching the next dataset.
  while :; do
    state="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["state"]}' \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["state"] if d else "GONE")')"
    case "$state" in
      SUCCESS)
        log "OK    $ds"
        break
        ;;
      FAILED|ABORTED)
        reason="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["error"]}' \
          | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d[0].get("error") or "").replace(chr(10)," ")[:300] if d else "")')"
        record_fail "$ds" "$reason"
        break
        ;;
      GONE)
        record_fail "$ds" "job $jid vanished"
        break
        ;;
      *)
        sleep "$POLL"
        ;;
    esac
  done
done < "$TMP"

log "chain done (fail=$fail)"

# Email a dataset-named summary only on failure (silent on success).
if [ -s "$FAILS" ]; then
  nfail="$(grep -c '^  - ' "$FAILS")"
  { printf 'cloudsync-chain: %s dataset(s) FAILED to back up on %s at %s.\n\n' \
      "$nfail" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
    cat "$FAILS"
    printf '\nThe other datasets were pushed normally. Full log: %s\n' "$LOG"
  } | send_mail "[NAS] Cloud Sync backup FAILED — $nfail dataset(s)"
fi

exit "$fail"
