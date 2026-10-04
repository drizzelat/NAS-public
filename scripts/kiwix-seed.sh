#!/bin/sh
# Keep qBittorrent seeding the newest Kiwix ZIM of each flavour below, and drop what they supersede
# once the new copy is complete. Runs on the NAS. Docs: docs/runbooks/setup-operations/kiwix-seeding.md
set -eu

# <mirror directory>/<flavour>, in priority order: a flavour that would pass the budget is not seeded.
# `-` not `:-`: an explicitly empty list means "seed nothing" and prunes the category.
FLAVOURS="${KIWIX_SEED_FLAVOURS-wikipedia/wikipedia_en_all_maxi wikipedia/wikipedia_de_all_maxi wikipedia/wikipedia_en_all_nopic wikipedia/wikipedia_de_all_nopic gutenberg/gutenberg_de_all}"
BUDGET_GB="${KIWIX_SEED_BUDGET_GB:-300}"
MIRROR="https://download.kiwix.org/zim"
CATEGORY="kiwix"
SAVE_PATH="/data/torrents/kiwix"   # qbittorrent's view of /mnt/data/mediaserver/data/torrents/kiwix

LOG="${KIWIX_SEED_LOG:-/var/log/kiwix-seed.log}"
LOCK="/tmp/kiwix-seed.lock"

# Fall back to stdout where /var/log is not root-writable.
if { : >>"$LOG"; } 2>/dev/null; then
  exec >>"$LOG" 2>&1
fi

log() { echo "$(date '+%F %T') $*"; }

exec 9>"$LOCK"
flock -n 9 || { log "skip: another run holds the lock"; exit 0; }

# Failure email (mirrors pg-dump-backup.sh); TrueNAS's own cron mail goes nowhere.
send_mail() {  # $1 = subject; body on stdin
  to="$(midclt call mail.config 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("fromemail") or "")' 2>/dev/null || true)"
  [ -n "$to" ] || { log "ERROR: no mail recipient configured — cannot send alert"; return 0; }
  SUBJ="$1" TO="$to" python3 -c '
import os, sys, json, subprocess
payload = json.dumps({"subject": os.environ["SUBJ"],
                      "text": sys.stdin.read(),
                      "to": [os.environ["TO"]]})
subprocess.run(["midclt", "call", "mail.send", payload],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
' 2>/dev/null || true
}

# Anything that leaves a flavour on the file it already has — a listing that does not parse, a
# .torrent that does not resolve, a run that dies — is mailed at exit. Otherwise a mirror format
# change would keep an old file seeding indefinitely with only a line in the log to show for it.
PROBLEMS=""
problem() {  # problem <message>
  log "WARN: $1"
  PROBLEMS="$PROBLEMS  - $1
"
}
fail() {  # fail <message>
  log "ERROR: $1"
  PROBLEMS="$PROBLEMS  - $1
"
  exit 1
}
report() {
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$PROBLEMS" ]; then
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    subject="[NAS] Kiwix seeding: a flavour could not update"
    outcome="The run finished. Each flavour above keeps seeding the file it already has until this clears."
  else
    subject="[NAS] Kiwix seeding ABORTED"
    outcome="The run stopped (exit status $rc) before it finished: nothing after that point was added or pruned."
    if [ -z "$PROBLEMS" ]; then  # set -e stopped it on a command with no message of its own
      log "ERROR: stopped by a failing command (exit status $rc)"
      PROBLEMS="  - a command failed without a message of its own; the log shows how far the run got
"
    fi
  fi
  printf 'kiwix-seed on %s at %s:\n\n%s\n%s\n\nLog: %s\nRunbook: docs/runbooks/setup-operations/kiwix-seeding.md\n' \
    "$(hostname)" "$(date '+%F %T')" "$PROBLEMS" "$outcome" "$LOG" \
    | send_mail "$subject"
}
trap report EXIT

# qBittorrent's Web API from inside its own network namespace, where localhost needs no login
# (the same bypass gluetun's port-forward hook uses — docs/services/downloads.md).
qbt() {  # qbt <endpoint> [curl args...]
  endpoint="$1"; shift
  docker exec qbittorrent curl -fsS --max-time 60 "$@" "http://127.0.0.1:8082/api/v2/$endpoint"
}

# Newest "<file> <GB, rounded up>" of a flavour, from the mirror's directory listing.
newest() {  # newest <directory> <flavour>
  curl -fsSL --max-time 60 "$MIRROR/$1/" \
    | sed -n "s/.*href=\"\($2_[0-9]\{4\}-[0-9]\{2\}\.zim\)\">.* \([0-9.]\{1,\}\)\([KMG]\) *\$/\1 \2 \3/p" \
    | sort | tail -n 1 \
    | awk '{ n = $2 / ($3 == "G" ? 1 : ($3 == "M" ? 1024 : 1048576)); g = int(n); if (g < n) g++; print $1, g }'
}

command -v docker >/dev/null 2>&1 || fail "docker CLI not found"
if [ "$(docker inspect -f '{{.State.Running}}' qbittorrent 2>/dev/null)" != "true" ]; then
  log "skip: qbittorrent is not running"
  exit 0
fi

cats="$(qbt torrents/categories)" || fail "qBittorrent Web API unreachable"
if ! printf '%s' "$cats" | jq -e --arg c "$CATEGORY" 'has($c)' >/dev/null; then
  qbt torrents/createCategory --data-urlencode "category=$CATEGORY" --data-urlencode "savePath=$SAVE_PATH" >/dev/null
  log "created category $CATEGORY ($SAVE_PATH)"
fi
seeding="$(qbt torrents/info -G --data-urlencode "category=$CATEGORY")"

keep=""   # torrent names this run wants, one per line
used=0
for entry in $FLAVOURS; do
  dir="${entry%/*}"
  flavour="${entry#*/}"
  found="$(newest "$dir" "$flavour" || true)"
  if [ -z "$found" ]; then
    # A failed or reformatted listing must not read as "flavour removed": keep what is seeding.
    held="$(printf '%s' "$seeding" | jq -r --arg f "${flavour}_" '.[] | select(.name | startswith($f)) | .name')"
    keep="$keep
$held"
    problem "no ${flavour}_YYYY-MM.zim in $MIRROR/$dir/ — keeping what is seeding"
    continue
  fi

  file="${found% *}"
  gb="${found#* }"
  if [ $((used + gb)) -gt "$BUDGET_GB" ]; then
    log "skip $file: ${gb} GB would take the total past ${BUDGET_GB} GB"
    continue
  fi
  used=$((used + gb))
  keep="$keep
$file"

  if printf '%s' "$seeding" | jq -e --arg n "$file" 'any(.[]; .name == $n)' >/dev/null; then
    continue
  fi
  url="$(curl -fsSIL --max-time 60 -o /dev/null -w '%{url_effective}' "$MIRROR/$dir/$file.torrent")" \
    || { problem "cannot resolve $file.torrent — retrying next run"; continue; }
  # -1 = no share limit on this torrent, whatever the global ratio and seeding-time rules say.
  qbt torrents/add -F "urls=$url" -F "category=$CATEGORY" -F "savepath=$SAVE_PATH" -F "autoTMM=false" \
    -F "ratioLimit=-1" -F "seedingTimeLimit=-1" -F "inactiveSeedingTimeLimit=-1" >/dev/null
  log "added $file (${gb} GB)"
done

# Prune only once every kept torrent is present and complete, so no flavour goes without a seeded copy.
seeding="$(qbt torrents/info -G --data-urlencode "category=$CATEGORY")"
keep_json="$(printf '%s\n' "$keep" | jq -R -s 'split("\n") | map(select(length > 0))')"
waiting="$(printf '%s' "$seeding" | jq -r --argjson k "$keep_json" \
  '$k - [.[] | select(.progress == 1) | .name] | join(" ")')"
if [ -n "$waiting" ]; then
  log "not pruning yet — still downloading or not added: $waiting"
else
  stale="$(printf '%s' "$seeding" | jq -r --argjson k "$keep_json" \
    '[.[] | select(.name as $n | $k | any(.[]; . == $n) | not)]')"
  hashes="$(printf '%s' "$stale" | jq -r 'map(.hash) | join("|")')"
  if [ -n "$hashes" ]; then
    qbt torrents/delete --data-urlencode "hashes=$hashes" --data-urlencode "deleteFiles=true" >/dev/null
    log "removed with their files: $(printf '%s' "$stale" | jq -r 'map(.name) | join(" ")')"
  fi
fi

log "done: ${used} GB of the ${BUDGET_GB} GB budget wanted"
