#!/bin/sh
# Monthly proof that the OFFSITE copy restores, in two parts, touching nothing in production:
#  1. pull apps/kuma back from Hetzner into a scratch path, decrypt it, integrity-check the
#     SQLite DB, compare the file count with the live dataset;
#  2. pull one database's dumps back the same way (one per month, in rotation), load the newest
#     into a throwaway container of the live image, and compare it with the live database.
# Docs: docs/runbooks/backup-restore/restore-drill.md

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

# Part 2. Same discovery as pg-dump-backup.sh: the nas.backup.* labels, on these Docker endpoints.
DB_HOSTS="
nas|
"
LABEL_FILTER="label=nas.backup.dump=true"
INSPECT_FMT='{{index .Config.Labels "nas.backup.user"}}|{{index .Config.Labels "nas.backup.db"}}|{{index .Config.Labels "nas.backup.dir"}}|{{index .Config.Labels "nas.backup.engine"}}|{{.Config.Image}}'
DRILL_CT=restore-drill-db
# The newest offsite dump may be this old: dumps run nightly at 02:30.
DUMP_MAX_AGE_H=48
# RESTORE_DRILL_DB=<host>/<db> picks the database instead of the rotation; "all" restores every one.
PICK="${RESTORE_DRILL_DB:-}"

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
  docker rm -f "$DRILL_CT" >/dev/null 2>&1 || true
  # Never let an empty or short SCRATCH turn this into rm -rf /.
  case "$SCRATCH" in
    /mnt/apps/restore-drill*) rm -rf "$SCRATCH" 2>/dev/null || true ;;
    *) err "refusing to delete unexpected scratch path $SCRATCH" ;;
  esac
}

# pull <remote folder> <local dir>: re-point the PULL task and run it. The credential and the
# crypt password/salt stay in the middleware: this never reads them.
pull() {
  payload="$(FOLDER="$1" DEST="$2" python3 -c '
import os, json
print(json.dumps({"path": os.environ["DEST"], "attributes": {"folder": os.environ["FOLDER"]}}))
')"
  midclt call cloudsync.update "$TASK_ID" "$payload" >/dev/null 2>&1 \
    || fatal "cloudsync.update rejected $1 -> $2"
  mkdir -p "$2" || fatal "cannot create $2"

  jid="$(midclt call cloudsync.sync "$TASK_ID" 2>/dev/null)"
  [ -n "$jid" ] || fatal "could not start the PULL job for $1"

  while :; do
    state="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["state"]}' \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["state"] if d else "GONE")')"
    case "$state" in
      SUCCESS) break ;;
      FAILED|ABORTED)
        reason="$(midclt call core.get_jobs "[[\"id\",\"=\",$jid]]" '{"select":["error"]}' \
          | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d[0].get("error") or "").replace(chr(10)," ")[:300] if d else "")')"
        fatal "PULL job for $1 $state: $reason"
        ;;
      GONE) fatal "PULL job $jid for $1 vanished" ;;
      *) sleep "$POLL" ;;
    esac
  done
}

# sql <endpoint> <container> <engine> <user> <db> <password|""> <query> -> one value per row.
# An empty password means the live container: postgres trusts its local socket, and mariadb reads
# its own root password from the container env.
sql() {
  if [ "$3" = mariadb ]; then
    if [ -n "$6" ]; then
      # shellcheck disable=SC2086  # $1 must word-split: empty = local docker
      docker $1 exec -e Q="$7" -e P="$6" "$2" sh -c 'exec mariadb -uroot -p"$P" -N -B -e "$Q"'
    else
      # shellcheck disable=SC2086
      docker $1 exec -e Q="$7" "$2" sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -N -B -e "$Q"'
    fi
  else
    # shellcheck disable=SC2086
    docker $1 exec "$2" psql -X -q -At -U "$4" -d "$5" -c "$7"
  fi
}

# restore_db <host> <endpoint> <container> <user> <db> <dir> <engine> <image>
restore_db() {
  host="$1" hep="$2" live_ct="$3" user="$4" db="$5" dir="$6" engine="$7" image="$8"
  tag="$host/$db"
  case "$dir" in
    /mnt/*) remote="/backup/${dir#/mnt/}" ;;
    *) fatal "$tag: dump dir $dir is not under /mnt, so it has no offsite copy" ;;
  esac
  dest="$SCRATCH/db-$host-$db"
  log "db    $tag: pulling $remote"
  pull "$remote" "$dest"

  # Dated names sort in time order; the prefix match is exact up to the underscore before the date.
  dump="$(find "$dest" -maxdepth 1 -type f -name "${db}_20*.sql.gz" | sort | tail -1)"
  [ -n "$dump" ] || fatal "$tag: no ${db}_*.sql.gz in the restored copy of $remote"
  stamp="$(basename "$dump" .sql.gz)"; stamp="${stamp#"${db}"_}"   # YYYY-MM-DD_HH-MM
  when="$(date -d "$(echo "$stamp" | sed 's/_/ /; s/-\([0-9][0-9]\)$/:\1/')" +%s 2>/dev/null)" \
    || fatal "$tag: cannot read a date from $(basename "$dump")"
  age_h=$(( ($(date +%s) - when) / 3600 ))
  [ "$age_h" -le "$DUMP_MAX_AGE_H" ] || fatal "$tag: newest offsite dump $(basename "$dump") is ${age_h} h old"

  # No pipefail in sh: a truncated gzip still feeds the loader a clean-looking prefix, so prove the
  # file is whole first, the same way pg-dump-backup.sh does.
  gzip -t "$dump" 2>/dev/null || fatal "$tag: $(basename "$dump") fails gzip -t"
  if [ "$engine" = mariadb ]; then marker='^-- Dump completed'; else marker='^-- PostgreSQL database dump complete'; fi
  gzip -cd "$dump" | tail -c 200 | grep -q "$marker" || fatal "$tag: $(basename "$dump") has no completion marker"

  # The live image and command (immich's config_file=, for one), no network, no mounts.
  # shellcheck disable=SC2086  # $hep must word-split: empty = local docker
  cmd="$(docker $hep inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$live_ct" 2>/dev/null)" \
    || fatal "$tag: cannot inspect $live_ct"
  docker rm -f "$DRILL_CT" >/dev/null 2>&1
  if [ "$engine" = mariadb ]; then
    # shellcheck disable=SC2086  # $cmd must word-split into the container's argv
    docker run -d --name "$DRILL_CT" --network none --memory 2g --cpus 2 \
      -e MARIADB_ROOT_PASSWORD=drill -e MARIADB_USER="$user" -e MARIADB_PASSWORD=drill \
      "$image" $cmd >/dev/null 2>&1 || fatal "$tag: cannot start a throwaway $image"
    ready='MariaDB init process done'
  else
    # shellcheck disable=SC2086
    docker run -d --name "$DRILL_CT" --network none --memory 2g --cpus 2 \
      -e POSTGRES_PASSWORD=drill -e POSTGRES_USER="$user" -e POSTGRES_DB="$db" \
      "$image" $cmd >/dev/null 2>&1 || fatal "$tag: cannot start a throwaway $image"
    ready='PostgreSQL init process complete'
  fi
  # The entrypoint runs a temporary server during init; wait for the real one.
  i=0
  until docker logs "$DRILL_CT" 2>&1 | grep -q "$ready" \
      && if [ "$engine" = mariadb ]; then docker exec "$DRILL_CT" mariadb-admin -uroot -pdrill ping >/dev/null 2>&1
         else docker exec "$DRILL_CT" pg_isready -U "$user" -d "$db" >/dev/null 2>&1; fi; do
    i=$((i + 1))
    [ "$i" -lt 90 ] || fatal "$tag: the throwaway database never became ready"
    sleep 2
  done

  t0=$(date +%s)
  if [ "$engine" = mariadb ]; then
    # The dump carries its own CREATE DATABASE and USE (mariadb-dump --databases).
    gzip -cd "$dump" | timeout 3600 docker exec -i "$DRILL_CT" mariadb -uroot -pdrill >/dev/null 2>"$SCRATCH/load.err"
  else
    gzip -cd "$dump" | timeout 3600 docker exec -i "$DRILL_CT" psql -X -q -v ON_ERROR_STOP=1 -U "$user" -d "$db" >/dev/null 2>"$SCRATCH/load.err"
  fi
  rc=$?
  [ "$rc" -eq 0 ] || fatal "$tag: loading $(basename "$dump") failed (rc $rc): $(grep -m1 -iE 'error' "$SCRATCH/load.err" | cut -c1-300)"
  secs=$(( $(date +%s) - t0 ))

  # Same tables as live, and the live database's biggest table is not empty in the copy.
  if [ "$engine" = mariadb ]; then
    q_tables="select count(*) from information_schema.tables where table_schema='$db' and table_type='BASE TABLE'"
    q_big="select table_name from information_schema.tables where table_schema='$db' and table_type='BASE TABLE' order by table_rows desc limit 1"
    big_ref() { echo "\`$db\`.\`$1\`"; }
  else
    q_tables="select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema') and table_type='BASE TABLE'"
    q_big="select quote_ident(schemaname)||'.'||quote_ident(relname) from pg_stat_user_tables order by n_live_tup desc limit 1"
    big_ref() { echo "$1"; }
  fi
  live_tables="$(sql "$hep" "$live_ct" "$engine" "$user" "$db" "" "$q_tables" 2>/dev/null)"
  drill_tables="$(sql "" "$DRILL_CT" "$engine" "$user" "$db" drill "$q_tables" 2>/dev/null)"
  [ -n "$live_tables" ] && [ -n "$drill_tables" ] || fatal "$tag: cannot count tables (live '$live_tables', restored '$drill_tables')"
  [ "$live_tables" = "$drill_tables" ] || fatal "$tag: restored $drill_tables tables, live has $live_tables"

  big="$(sql "$hep" "$live_ct" "$engine" "$user" "$db" "" "$q_big" 2>/dev/null)"
  [ -n "$big" ] || fatal "$tag: cannot find the live database's biggest table"
  q_rows="select count(*) from $(big_ref "$big")"
  live_rows="$(sql "$hep" "$live_ct" "$engine" "$user" "$db" "" "$q_rows" 2>/dev/null)"
  drill_rows="$(sql "" "$DRILL_CT" "$engine" "$user" "$db" drill "$q_rows" 2>/dev/null)"
  case "$live_rows$drill_rows" in *[!0-9]*|'') fatal "$tag: cannot count rows in $big (live '$live_rows', restored '$drill_rows')" ;; esac
  # The live database moves after the dump, so a band, not equality.
  if [ "$live_rows" -gt 0 ] && { [ "$drill_rows" -eq 0 ] || [ "$((drill_rows * 2))" -lt "$live_rows" ]; }; then
    fatal "$tag: $big has $drill_rows rows restored, $live_rows live — the dump is short"
  fi

  log "OK    $tag: $(basename "$dump") (${age_h} h old) loaded into $image in ${secs}s; $drill_tables tables as live, $big $drill_rows rows (live $live_rows)"
  docker rm -f "$DRILL_CT" >/dev/null 2>&1
  rm -rf "$dest" "$SCRATCH/load.err"
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

cleanup
pull "$REMOTE_FOLDER" "$SCRATCH"

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

## Part 2: one database, in rotation

mkdir -p "$SCRATCH" || fatal "cannot create $SCRATCH"
UNITS="$SCRATCH/units"
: > "$UNITS" || fatal "cannot write $UNITS"
while IFS='|' read -r hname hep; do
  [ -n "$hname" ] || continue
  # shellcheck disable=SC2086
  names="$(docker $hep ps --filter "$LABEL_FILTER" --format '{{.Names}}' 2>&1)" \
    || fatal "$hname: cannot list containers — $names"
  for c in $names; do
    # shellcheck disable=SC2086
    meta="$(docker $hep inspect -f "$INSPECT_FMT" "$c" 2>&1)" || fatal "$hname/$c: inspect failed — $meta"
    IFS='|' read -r user dbs dir engine image <<EOF2
$meta
EOF2
    for d in $(echo "$dbs" | tr ',' ' '); do
      echo "$hname/$d|$hname|$hep|$c|$user|$d|$dir|${engine:-postgres}|$image" >> "$UNITS"
    done
  done
done <<EOF
$DB_HOSTS
EOF
sort -o "$UNITS" "$UNITS"
count="$(wc -l < "$UNITS")"
[ "$count" -gt 0 ] || { fatal "no running container carries $LABEL_FILTER — nothing to restore"; }

case "$PICK" in
  all) picked="$(cat "$UNITS")" ;;
  '')
    # One per month, so every database comes round within a year while there are 12 or fewer.
    n=$(( ($(date +%Y) * 12 + $(date +%-m)) % count + 1 ))
    picked="$(sed -n "${n}p" "$UNITS")"
    ;;
  *) picked="$(awk -F'|' -v p="$PICK" '$1 == p' "$UNITS")"
     [ -n "$picked" ] || { fatal "RESTORE_DRILL_DB=$PICK is not one of: $(cut -d'|' -f1 "$UNITS" | tr '\n' ' ')"; } ;;
esac
rm -f "$UNITS"

while IFS='|' read -r _ hname hep c user d dir engine image; do
  [ -n "$d" ] || continue
  restore_db "$hname" "$hep" "$c" "$user" "$d" "$dir" "$engine" "$image"
done <<EOF
$picked
EOF
cleanup

if [ -r "$PUSH_URL_FILE" ]; then
  url="$(cat "$PUSH_URL_FILE")"
  [ -n "$url" ] && curl -fsS -m 15 "$url" >/dev/null 2>&1 || true
fi

log "drill done"
exit 0
