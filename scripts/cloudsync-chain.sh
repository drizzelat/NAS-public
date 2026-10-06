#!/bin/sh
# Drive ONE template Cloud Sync task across every backed-up leaf dataset, SERIALLY
# (the box caps connections). Keep the lists below in sync with docs/runbooks/backup-restore/backup.md.

set -u

LOG=/var/log/cloudsync-chain.log
POLL=15                       # seconds between job-state polls
LOCK=/var/run/cloudsync-chain.lock

# The Storage Box sometimes stalls or refuses every new SFTP channel for an hour (2026-10-05:
# 40 of 43 datasets failed, one 30-min timeout at a time). So before each dataset the chain
# checks the box answers, waits for it if not, and gives up on the REST of the run (loudly) only
# when it stays down. A dataset that fails on a connection error is retried once.
GATE_POLL=60                  # seconds between box probes while waiting for it
GATE_MAX=1200                 # give up on the remaining datasets after this long
RETRIES=1                     # extra attempts for a connection-type failure

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
  '{"select":["id","description","attributes","credentials"]}')" \
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

# Reachability probe: list the remote root through the template's own credentials. It opens
# a real SFTP channel, so it fails exactly when the box is refusing them.
PROBE_REQ="$(printf '%s' "$TEMPLATE_JSON" | python3 -c '
import sys, json
t = json.load(sys.stdin)[0]
a = dict(t["attributes"]); a["folder"] = "/backup"
c = t["credentials"]
print(json.dumps({"credentials": c["id"] if isinstance(c, dict) else c,
                  "encryption": False, "attributes": a, "args": ""}))
')" || fatal "could not build the Storage Box probe request"

box_ok() {
  PROBE="$PROBE_REQ" python3 -c '
import os, subprocess, sys
try:
    r = subprocess.run(["midclt", "call", "cloudsync.list_directory", os.environ["PROBE"]],
                       capture_output=True, text=True, timeout=75)
except subprocess.TimeoutExpired:
    sys.exit(1)
sys.exit(0 if r.returncode == 0 else 1)
' >/dev/null 2>&1
}

# 0 = box answers (possibly after waiting), 1 = still down after GATE_MAX.
wait_for_box() {
  box_ok && return 0
  waited=0
  err "WAIT  Storage Box not answering; probing every ${GATE_POLL}s for up to ${GATE_MAX}s"
  while [ "$waited" -lt "$GATE_MAX" ]; do
    sleep "$GATE_POLL"
    waited=$((waited + GATE_POLL))
    if box_ok; then
      log "box answering again after ${waited}s"
      return 0
    fi
  done
  return 1
}

# A connection-type failure: the box or the path to it, which a pause usually cures.
transient() {  # $1 = rclone error text
  printf '%s' "$1" | grep -qiE \
    'connection lost|connection refused|connection reset|channel open|initialise SFTP|i/o timeout|timed out|broken pipe|unexpected EOF'
}

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

DATA_INCLUDE = ("data/immich", "data/smb_share")
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
SKIPPED="$(mktemp)"
trap 'idle; rm -f "$TMP" "$FAILS" "$SKIPPED"' EXIT
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
REASON=""

# Push ONE dataset. Returns 0 on success; on failure returns 1 with the reason in $REASON.
run_dataset() {  # $1 = dataset
  ds="$1"

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
    REASON="cloudsync.update rejected the payload"
    return 1
  fi

  log "START $ds"
  jid="$(midclt call cloudsync.sync "$TEMPLATE_ID" 2>/dev/null)"
  if [ -z "$jid" ]; then
    REASON="could not start sync"
    return 1
  fi

  # Poll until the job is terminal before touching the next dataset.
  while :; do
    state="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["state"]}' \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["state"] if d else "GONE")')"
    case "$state" in
      SUCCESS)
        log "OK    $ds"
        return 0
        ;;
      FAILED|ABORTED)
        REASON="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["error"]}' \
          | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d[0].get("error") or "").replace(chr(10)," ")[:300] if d else "")')"
        return 1
        ;;
      GONE)
        REASON="job $jid vanished"
        return 1
        ;;
      *)
        sleep "$POLL"
        ;;
    esac
  done
}

# Box down for good: everything still queued is logged and mailed as NOT ATTEMPTED.
box_down=0
skip() {  # $1 = dataset
  err "SKIP  $1: Storage Box unreachable"
  fail=1
  printf '  - %s\n' "$1" >> "$SKIPPED"
}

while IFS= read -r ds; do
  [ -z "$ds" ] && continue

  if [ "$box_down" = 1 ]; then
    skip "$ds"
    continue
  fi

  attempt=0
  while :; do
    if ! wait_for_box; then
      box_down=1
      err "Storage Box still unreachable after ${GATE_MAX}s; abandoning the rest of the run"
      skip "$ds"
      break
    fi
    if run_dataset "$ds"; then
      break
    fi
    if transient "$REASON" && [ "$attempt" -lt "$RETRIES" ]; then
      attempt=$((attempt + 1))
      err "RETRY $ds ($attempt/$RETRIES): $REASON"
      continue
    fi
    record_fail "$ds" "$REASON"
    break
  done
done < "$TMP"

log "chain done (fail=$fail)"

# Email a dataset-named summary only on failure (silent on success).
if [ -s "$FAILS" ] || [ -s "$SKIPPED" ]; then
  nfail=0; nskip=0
  [ -s "$FAILS" ] && nfail="$(grep -c '^  - ' "$FAILS")"
  [ -s "$SKIPPED" ] && nskip="$(grep -c '^  - ' "$SKIPPED")"
  { if [ "$nskip" -gt 0 ]; then
      printf 'cloudsync-chain on %s at %s: the Hetzner Storage Box stopped answering for over %ss.\n' \
        "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$GATE_MAX"
      printf '%s dataset(s) were NOT ATTEMPTED and %s failed. Re-run the chain once the box is back:\n' \
        "$nskip" "$nfail"
      printf '  sudo /bin/sh /mnt/apps/scripts/nas/scripts/cloudsync-chain.sh\n\n'
    else
      printf 'cloudsync-chain: %s dataset(s) FAILED to back up on %s at %s.\n\n' \
        "$nfail" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
    fi
    if [ "$nfail" -gt 0 ]; then
      printf 'FAILED:\n'; cat "$FAILS"; printf '\n'
    fi
    if [ "$nskip" -gt 0 ]; then
      printf 'NOT ATTEMPTED:\n'; cat "$SKIPPED"; printf '\n'
    fi
    printf 'The other datasets were pushed normally. Full log: %s\n' "$LOG"
  } | send_mail "[NAS] Cloud Sync backup FAILED — $nfail failed, $nskip not attempted"
fi

exit "$fail"
