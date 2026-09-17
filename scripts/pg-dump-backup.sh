#!/bin/sh
# Logical backups of every LABELLED application DB (pg_dump / mariadb-dump) into a
# dumps/ dir the nightly push carries offsite. Docs: docs/runbooks/backup-restore/postgres-dump.md

set -eu

RETENTION_DAYS=7
STAMP="$(date +%Y-%m-%d_%H-%M)"

# Optional Uptime-Kuma push monitor, pinged on FULL success; a late ping catches
# the job not running at all. Host file, not the repo — no token committed.
PUSH_URL_FILE="/root/.config/pg-dump-kuma-push.url"

# Last run's discovered set. A DB that silently drops OUT of discovery is the one
# failure mode label-driven discovery adds, so it is compared and alerted on.
STATE_FILE="/root/.local/state/nas-db-dump-discovered"

# Docker endpoints to scan: "name|docker -H value". Empty value = this host.
# A remote entry needs root's SSH key trusted there and its own known_hosts row.
HOSTS="
nas|
a1|-H ssh://a1-docker
"

# Databases opt in from their own compose file, so a new DB stack is backed up by
# construction. Required: .db (comma-separated for several) .user .dir; .engine defaults
# to postgres. .dir is always a path on THIS host — a remote dump streams back here.
LABEL_FILTER="label=nas.backup.dump=true"
INSPECT_FMT='{{index .Config.Labels "nas.backup.user"}}|{{index .Config.Labels "nas.backup.db"}}|{{index .Config.Labels "nas.backup.dir"}}|{{index .Config.Labels "nas.backup.engine"}}|{{.State.Running}}'

# Dump one DB to stdout, picking the engine.
dump_db() {  # $1 -H value | $2 container | $3 db-user | $4 db-name | $5 engine
  if [ "$5" = "mariadb" ]; then
    # shellcheck disable=SC2086  # $1 must word-split: empty = local docker
    docker $1 exec -e DUMP_DB="$4" "$2" \
      sh -c 'exec mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" --single-transaction --databases "$DUMP_DB"'
  else
    # shellcheck disable=SC2086
    docker $1 exec "$2" pg_dump --clean --if-exists --username="$3" "$4"
  fi
}

# gzip exits 0 on a truncated stream, so only the dumper's own end marker proves the
# dump ran to completion. Docs: docs/runbooks/backup-restore/postgres-dump.md
dump_complete() {  # $1 = .sql.gz file | $2 = engine
  if [ "$2" = "mariadb" ]; then
    gzip -cd -- "$1" | tail -c 200 | grep -q '^-- Dump completed'
  else
    gzip -cd -- "$1" | tail -c 200 | grep -q '^-- PostgreSQL database dump complete'
  fi
}

# Failure email (mirrors cloudsync-chain.sh); TrueNAS's own cron mail goes nowhere.
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

DISCOVERED="$(mktemp)"
DUMPED="$(mktemp)"
trap 'rm -f "$DISCOVERED" "$DUMPED"' EXIT

# Feed every loop with a here-doc, NOT a pipe: a piped `while` runs in a subshell,
# so PROBLEMS set inside it would be lost.
PROBLEMS=""

problem() {
  echo "$1" >&2
  PROBLEMS="${PROBLEMS}${1}\n"
}

## 1. Discover

while IFS='|' read -r hname hendpoint; do
  [ -n "$hname" ] || continue

  # shellcheck disable=SC2086
  if ! names="$(docker $hendpoint ps -a --filter "$LABEL_FILTER" --format '{{.Names}}' 2>&1)"; then
    problem "ERROR $hname: cannot list containers — $names"
    continue
  fi

  for c in $names; do
    # shellcheck disable=SC2086
    if ! meta="$(docker $hendpoint inspect -f "$INSPECT_FMT" "$c" 2>&1)"; then
      problem "ERROR $hname/$c: inspect failed — $meta"
      continue
    fi
    echo "$hname|$hendpoint|$c|$meta" >> "$DISCOVERED"
  done
done <<EOF
$HOSTS
EOF

# Zero labelled containers anywhere is never correct — it means the label was
# dropped estate-wide, or docker is down. Fail loudly rather than back up nothing.
if [ ! -s "$DISCOVERED" ]; then
  problem "ERROR no container carries $LABEL_FILTER on any configured host — nothing to back up"
fi

## 2. Dump

while IFS='|' read -r hname hendpoint container user dbs dir engine running; do
  [ -n "$container" ] || continue

  if [ -z "$dbs" ] || [ -z "$user" ] || [ -z "$dir" ]; then
    problem "ERROR $hname/$container: incomplete backup labels (db='$dbs' user='$user' dir='$dir')"
    continue
  fi

  # One container may host several databases (the A1 holds synapse + the bridge).
  for db in $(echo "$dbs" | tr ',' ' '); do
    tag="$hname/$db"
    echo "$hname|$container|$db" >> "$DUMPED"

    if [ "$running" != "true" ]; then
      problem "SKIP $tag: container '$container' is not running"
      continue
    fi

    mkdir -p "$dir"
    out="$dir/${db}_${STAMP}.sql.gz"

    echo "Dumping $tag ($container) -> $out"
    # No pipefail in POSIX sh: this `if` sees gzip's status, never the dumper's, so a
    # dump that died mid-stream still gzips cleanly. dump_complete is what catches it.
    if dump_db "$hendpoint" "$container" "$user" "$db" "$engine" | gzip -c > "$out.tmp"; then
      if dump_complete "$out.tmp" "$engine"; then
        mv "$out.tmp" "$out"
        # Prune only after a verified dump, so a bad night cannot delete good history.
        find "$dir" -name "${db}_*.sql.gz" -type f -mtime "+$RETENTION_DAYS" -delete
      else
        problem "ERROR truncated dump for $tag ($container) — no completion marker, discarded"
        rm -f "$out.tmp"
      fi
    else
      problem "ERROR dumping $tag ($container)"
      rm -f "$out.tmp"
    fi
  done
done < "$DISCOVERED"

## 3. Compare against the last run — a DB that vanishes must not vanish quietly

if [ -r "$STATE_FILE" ]; then
  while IFS= read -r prev; do
    [ -n "$prev" ] || continue
    grep -qxF "$prev" "$DUMPED" || problem "ERROR $prev was backed up last run but carries no $LABEL_FILTER now"
  done < "$STATE_FILE"
fi

if [ -z "$PROBLEMS" ]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  sort -u "$DUMPED" > "$STATE_FILE"
fi

if [ -n "$PROBLEMS" ]; then
  printf 'DB dump backup had failures on %s at %s:\n\n%b\nLog into the host and check; the safe logical restore path may be stale.\n' \
    "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$PROBLEMS" \
    | send_mail "[NAS] DB dump FAILED"
  exit 1
fi

# Full success -> ping the Kuma heartbeat if one is configured.
if [ -r "$PUSH_URL_FILE" ]; then
  url="$(cat "$PUSH_URL_FILE")"
  [ -n "$url" ] && curl -fsS -m 15 "$url" >/dev/null 2>&1 || true
fi

echo "All DB dumps OK."
