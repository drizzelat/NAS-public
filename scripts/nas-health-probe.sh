#!/bin/sh
# Forced command behind the health check's SSH key: a closed verb list and nothing else.
# Verbs, install and the sudo grants: docs/runbooks/setup-operations/nas-health-check.md
set -eu

CLONE=/mnt/apps/scripts/nas
DROPIN=/etc/systemd/system/docker.service.d/10-wait-for-data-root.conf
CLOUDSYNC_LOG=/var/log/cloudsync-chain.log
SMART_HELPER=/mnt/apps/scripts/nas-health-smart.sh
SELF=/mnt/apps/scripts/nas-health-probe.sh
# Installed outside the clone on purpose, so no pull updates them (komodo-migration.md F11).
HOST_COPIES="git-pull-nas.sh"
# The non-interactive PATH has no /usr/sbin, so everything is called absolute.
MIDCLT=/usr/bin/midclt
ZFS=/usr/sbin/zfs
ZPOOL=/usr/sbin/zpool

# Keep in step with usage() and the case below; a verb missing here is refused.
VERBS="help host alerts pools datasets snapshots smart disks cloudsync dumps
       paths repo-head boot-guard yaml2json version host-copies"

usage() {
  cat <<'EOF'
nas-health-probe — allowed verbs:
  help          this list
  host          failed systemd units, NTP sync, boot time
  alerts        midclt alert.list
  pools         zpool status + zpool list -o name,capacity,health
  datasets      zfs list -o name,mountpoint
  snapshots     zfs list -t snapshot -o name,creation (oldest first)
  smart         smartctl -H -A and -l selftest for every scanned device
  disks         midclt disk.query
  cloudsync     tail of the cloudsync-chain log + midclt cloudsync.query
  dumps DIR...  ls -l DIR, gzip -t and completion marker of its newest *.sql.gz
  paths PATH... whether each PATH exists
  repo-head     git rev-parse HEAD of the on-host repo clone
  boot-guard    the docker ordering drop-in, verbatim
  yaml2json     YAML on stdin -> JSON on stdout
  version       sha256 of this script and the SMART helper
  host-copies   sha256 of the scripts installed outside the clone
DIR/PATH must be absolute under /mnt, no '..', letters/digits/._-/ only.
EOF
}

deny() {
  printf 'nas-health-probe: refused (%s)\n' "$*" >&2
  exit 111
}

check_path() {
  case "$1" in
    *..*) deny "path traversal: $1" ;;
  esac
  case "$1" in
    /mnt/?*) ;;
    *) deny "path is not under /mnt: $1" ;;
  esac
  # Nothing outside this set ever reaches a command line.
  [ -z "$(printf '%s' "$1" | tr -d 'A-Za-z0-9._/-')" ] || deny "unsafe character in path: $1"
}

# Word-split the client's command line with globbing off; every argument that
# survives is checked before use.
set -f
# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-}
[ "$#" -ge 1 ] || { usage >&2; deny "no command"; }
verb="$1"
shift

# Checked before the arity rule below, so an unknown verb is reported as unknown
# rather than as one of the real verbs called with bad arguments.
known=false
for v in $VERBS; do
  [ "$v" = "$verb" ] && { known=true; break; }
done
[ "$known" = true ] || { usage >&2; deny "unknown verb: $verb"; }

# Everything except dumps/paths is argument-free; silently ignoring extras would
# make `smart /dev/sda` look like it did something device-specific.
case "$verb" in
  dumps|paths) ;;
  *) [ "$#" -eq 0 ] || deny "$verb takes no arguments" ;;
esac

case "$verb" in
  help)
    usage
    ;;

  host)
    echo "=== systemctl --failed ==="
    /usr/bin/systemctl --failed --no-legend || true
    echo "=== NTPSynchronized ==="
    /usr/bin/timedatectl show -p NTPSynchronized --value
    echo "=== booted ==="
    /usr/bin/uptime -s
    ;;

  alerts)
    exec sudo -n "$MIDCLT" call alert.list
    ;;

  pools)
    echo "=== zpool status ==="
    "$ZPOOL" status
    echo "=== zpool list ==="
    "$ZPOOL" list -H -o name,capacity,health
    ;;

  datasets)
    exec "$ZFS" list -H -o name,mountpoint
    ;;

  snapshots)
    exec "$ZFS" list -t snapshot -H -o name,creation -s creation
    ;;

  smart)
    exec sudo -n "$SMART_HELPER"
    ;;

  disks)
    exec sudo -n "$MIDCLT" call disk.query
    ;;

  cloudsync)
    echo "=== tail -n 200 $CLOUDSYNC_LOG ==="
    /usr/bin/tail -n 200 "$CLOUDSYNC_LOG"
    echo "=== cloudsync.query (task state only) ==="
    # The raw call returns the repository's encryption password and salt. Project
    # out the fields the check reads; the rest never leaves the host.
    sudo -n "$MIDCLT" call cloudsync.query | /usr/bin/python3 -c '
import json, sys
print(json.dumps([{
    "id": t.get("id"),
    "description": t.get("description"),
    "path": t.get("path"),
    "enabled": t.get("enabled"),
    "direction": t.get("direction"),
    "schedule": t.get("schedule"),
    "state": (t.get("job") or {}).get("state"),
    "time_started": (t.get("job") or {}).get("time_started"),
    "time_finished": (t.get("job") or {}).get("time_finished"),
    "error": (t.get("job") or {}).get("error"),
} for t in json.load(sys.stdin)], indent=1))
'
    ;;

  dumps)
    [ "$#" -ge 1 ] || deny "dumps needs at least one directory"
    for d in "$@"; do
      check_path "$d"
      echo "=== $d ==="
      [ -d "$d" ] || { echo "MISSING DIR"; continue; }
      ls -l -- "$d"
      # Globbing is off for the argv split above; re-enable it just for this match.
      set +f
      newest="$(ls -1t -- "$d"/*.sql.gz 2>/dev/null | head -n 1)"
      set -f
      [ -n "$newest" ] || { echo "no *.sql.gz in this directory"; continue; }
      echo "newest: $newest"
      if /usr/bin/gzip -t -- "$newest" 2>&1; then
        echo "gzip -t: OK"
      else
        echo "gzip -t: FAILED"
      fi
      # gzip -t only proves the container is intact; a dump killed mid-stream still
      # gzips cleanly. The dumper's end marker is what proves it ran to completion.
      if /usr/bin/gzip -cd -- "$newest" 2>/dev/null | tail -c 200 \
        | grep -qE '^-- (PostgreSQL database dump complete|Dump completed)'; then
        echo "complete: OK"
      else
        echo "complete: MISSING"
      fi
    done
    ;;

  paths)
    [ "$#" -ge 1 ] || deny "paths needs at least one path"
    for p in "$@"; do
      check_path "$p"
      if [ -e "$p" ]; then echo "OK      $p"; else echo "MISSING $p"; fi
    done
    ;;

  repo-head)
    # The clone is root-owned and this runs as another user, so git would refuse it.
    exec /usr/bin/git -c "safe.directory=$CLONE" -C "$CLONE" rev-parse HEAD
    ;;

  boot-guard)
    exec cat -- "$DROPIN"
    ;;

  yaml2json)
    exec /usr/bin/python3 -c 'import sys,yaml,json;json.dump(yaml.safe_load(sys.stdin),sys.stdout)'
    ;;

  version)
    exec /usr/bin/sha256sum "$SELF" "$SMART_HELPER"
    ;;

  host-copies)
    cd "${SELF%/*}"
    # HOST_COPIES is a word list on purpose.
    # shellcheck disable=SC2086
    exec /usr/bin/sha256sum $HOST_COPIES
    ;;

  *)
    deny "verb in VERBS but not implemented: $verb"
    ;;
esac
