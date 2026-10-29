#!/bin/sh
# NixOS build of scripts/nas-health-probe.sh (PLT-1 Phase 3 step 3): the same verbs over
# zpool/zfs/smartctl/systemctl instead of midclt. PATH comes from health-probe.nix; the
# root helpers are store paths with exact sudo grants. Verbs: nas-health-check.md
set -eu

CLONE=/mnt/apps/scripts/nas
DEPLOY_STATE=/var/lib/nas-host-deploy
SMART_HELPER=@smartHelper@
HETZNER_HELPER=@hetznerHelper@
RESTIC_LOG_HELPER=@resticLogHelper@
KUMA_HELPER=@kumaHelper@
# The static compose stacks/nas-periphery mounts (docker.nix): the same version the host applies with.
COMPOSE_PLUGIN=/usr/libexec/docker/cli-plugins/docker-compose
SELF="$0"

# Keep in step with usage() and the case below; a verb missing here is refused.
VERBS="help host alerts pools datasets snapshots smart disks cloudsync dumps
       paths repo-head boot-guard yaml2json compose-hash version host-copies storagebox kuma"

usage() {
  cat <<'EOF'
nas-health-probe (NixOS) — allowed verbs:
  help          this list
  host          failed systemd units, NTP sync, boot time
  alerts        failed units, zpool status -x, nas-notify alerts of the last 24 h
  pools         zpool status + zpool list -o name,capacity,health
  datasets      zfs list -o name,mountpoint
  snapshots     zfs list -t snapshot -o name,creation (epoch, oldest first)
  smart         smartctl -H -A and -l selftest for every scanned device
  disks         smartctl --scan-open + lsblk (model, size, rotational)
  cloudsync     restic backup unit state + the tail of its journal (the chain is gone)
  dumps DIR...  ls -l DIR, then per database in it: newest dump, gzip -t, end marker
  paths PATH... whether each PATH exists
  repo-head     git rev-parse HEAD of the on-host repo clone
  boot-guard    docker.service's declared pool guard (Requires/After/Assert)
  yaml2json     YAML on stdin -> JSON on stdout
  compose-hash  compose file on stdin -> the host compose version, then `<service> <config-hash>` per service
  version       sha256 of this script and its helpers
  host-copies   deployed main rev, running and booted system
  storagebox    Hetzner Storage Box snapshots, read-only API (token stays here)
  kuma          monitor definitions of both Uptime Kuma databases, a fixed column list
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
    systemctl --failed --no-legend || true
    echo "=== NTPSynchronized ==="
    timedatectl show -p NTPSynchronized --value
    echo "=== booted ==="
    uptime -s
    ;;

  alerts)
    echo "=== systemctl --failed ==="
    systemctl --failed --no-legend || true
    echo "=== zpool status -x ==="
    zpool status -x
    echo "=== nas-notify, last 24 h ==="
    journalctl -q --no-pager -t nas-notify --since -24h -o short-iso 2>&1 || true
    ;;

  pools)
    echo "=== zpool status ==="
    zpool status
    echo "=== zpool list ==="
    zpool list -H -o name,capacity,health
    ;;

  datasets)
    exec zfs list -H -o name,mountpoint
    ;;

  snapshots)
    # -p: creation as epoch seconds, so a reader never parses a locale-formatted date.
    exec zfs list -t snapshot -H -p -o name,creation -s creation
    ;;

  smart)
    exec sudo -n "$SMART_HELPER"
    ;;

  disks)
    echo "=== smartctl --scan-open ==="
    smartctl --scan-open 2>&1 || true
    echo "=== lsblk ==="
    lsblk -d -o NAME,SIZE,TYPE,ROTA,TRAN,MODEL
    ;;

  cloudsync)
    # The Cloud Sync chain is gone; BAK-1's restic job is what this verb reports now.
    echo "=== restic-backups-storagebox ==="
    systemctl show restic-backups-storagebox.service -p Result -p ActiveState \
      -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus
    echo "=== last success ==="
    cat /mnt/apps/observability/textfile/restic.prom 2>/dev/null || echo "never"
    echo "=== journal tail ==="
    sudo -n "$RESTIC_LOG_HELPER"
    ;;

  dumps)
    [ "$#" -ge 1 ] || deny "dumps needs at least one directory"
    for d in "$@"; do
      check_path "$d"
      echo "=== $d ==="
      [ -d "$d" ] || { echo "MISSING DIR"; continue; }
      ls -l -- "$d"
      # One directory can hold several databases (one can hold
      # several), so report per DATABASE, not per directory: the newest file
      # in the dir belongs to whichever DB dumped last and says nothing about the rest.
      # Globbing is off for the argv split above; re-enable it just for these matches.
      set +f
      dbs="$(ls -1 -- "$d"/*.sql.gz 2>/dev/null \
        | sed -e 's|.*/||' \
        | sed -n 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}\.sql\.gz$//p' \
        | sort -u)"
      set -f
      [ -n "$dbs" ] || { echo "no *.sql.gz in this directory"; continue; }
      for db in $dbs; do
        echo "--- db: $db ---"
        # The [0-9] keeps a 'foo' glob off 'foo_bar's stamped files.
        set +f
        newest="$(ls -1t -- "$d/${db}_"[0-9]*.sql.gz 2>/dev/null | head -n 1)"
        set -f
        [ -n "$newest" ] || { echo "no *.sql.gz for this database"; continue; }
        echo "newest: $newest"
        echo "mtime: $(stat -c %Y -- "$newest")"
        echo "size: $(stat -c %s -- "$newest")"
        # This DB's retained sizes only, for the "is this one suspiciously small"
        # comparison — a median mixing a 213 MB DB with a 6 MB one compares nothing.
        set +f
        echo "sizes: $(stat -c %s -- "$d/${db}_"[0-9]*.sql.gz 2>/dev/null | tr '\n' ' ')"
        set -f
        if gzip -t -- "$newest" 2>&1; then
          echo "gzip -t: OK"
        else
          echo "gzip -t: FAILED"
        fi
        # gzip -t only proves the container is intact; a dump killed mid-stream still
        # gzips cleanly. The dumper's end marker is what proves it ran to completion.
        if gzip -cd -- "$newest" 2>/dev/null | tail -c 200 \
          | grep -qE '^-- (PostgreSQL database dump complete|Dump completed)'; then
          echo "complete: OK"
        else
          echo "complete: MISSING"
        fi
      done
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
    exec git -c "safe.directory=$CLONE" -C "$CLONE" rev-parse HEAD
    ;;

  boot-guard)
    # TrueNAS's regenerated drop-in is a declared dependency here (docker.nix, storage.nix).
    # `systemctl show` cannot print the assert (-p AssertPathIsMountPoint is empty, Asserts is
    # [unprintable]), the unit file can.
    systemctl show docker.service -p Requires -p After
    systemctl cat docker.service | grep -E '^AssertPathIsMountPoint=' || true
    ;;

  yaml2json)
    exec python3 -c 'import sys,yaml,json;json.dump(yaml.safe_load(sys.stdin),sys.stdout)'
    ;;

  compose-hash)
    # config --hash only reads the file: no daemon, no root.
    "$COMPOSE_PLUGIN" version --short
    exec "$COMPOSE_PLUGIN" -p periphery -f - config --hash '*'
    ;;

  version)
    exec sha256sum "$SELF" "$SMART_HELPER" "$HETZNER_HELPER" "$RESTIC_LOG_HELPER" "$KUMA_HELPER"
    ;;

  storagebox)
    exec sudo -n "$HETZNER_HELPER"
    ;;

  kuma)
    exec sudo -n "$KUMA_HELPER"
    ;;

  host-copies)
    # Nothing is installed outside the store any more: report which main is deployed.
    echo "deployed-rev $(cat "$DEPLOY_STATE/rev" 2>/dev/null || echo none)"
    echo "running $(readlink -f /run/current-system)"
    echo "booted $(readlink -f /run/booted-system)"
    ;;

  *)
    deny "verb in VERBS but not implemented: $verb"
    ;;
esac
