#!/bin/sh
# Stop dockerd starting before its ZFS data-root is mounted, and heal a boot where
# it already did. POSTINIT. Docs: docs/runbooks/setup-operations/docker-image-prune.md

set -eu

DOCKER_ROOT="${DOCKER_ROOT:-/mnt/.ix-apps/docker}"
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN="$DROPIN_DIR/10-wait-for-data-root.conf"
WAIT_SECS="${WAIT_SECS:-120}"

LOG="${DOCKER_BOOT_GUARD_LOG:-/var/log/docker-boot-guard.log}"

if { : >>"$LOG"; } 2>/dev/null; then
  exec >>"$LOG" 2>&1
fi

log() { echo "$(date '+%F %T') $*"; }

if ! command -v docker >/dev/null 2>&1; then
  log "ERROR: docker CLI not found"
  exit 1
fi

# Ordering drop-in. `mountpoint -q` is the check that matters: the mountpoint DIR
# always exists, so a path test would pass in exactly the broken case.
install_dropin() {
  # The command line must contain NO dollar sign — systemd expands \$VAR in unit
  # files even inside single quotes, so `timeout` + `until` is used instead of a counter.
  want="[Unit]
# Installed by scripts/docker-boot-guard.sh (POSTINIT). Not RequiresMountsFor= —
# a middleware-mounted ZFS dataset has no .mount unit. Regenerated every boot.
[Service]
ExecStartPre=/bin/sh -c 'timeout $WAIT_SECS sh -c \"until mountpoint -q $DOCKER_ROOT; do sleep 1; done\" || { echo \"docker data-root $DOCKER_ROOT not mounted after ${WAIT_SECS}s\" >&2; exit 1; }'
"

  if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$want" ]; then
    log "ok: ordering drop-in already current ($DROPIN)"
    return 0
  fi

  mkdir -p "$DROPIN_DIR"
  printf '%s' "$want" >"$DROPIN"
  systemctl daemon-reload
  log "installed: ordering drop-in $DROPIN (waits up to ${WAIT_SECS}s for $DOCKER_ROOT)"
}

# Heal this boot. Blind = the daemon reports no images while the on-disk imagedb
# holds some; nothing else produces that signature.
disk_image_count() {
  d="$DOCKER_ROOT/image/overlay2/imagedb/content/sha256"
  [ -d "$d" ] || { echo 0; return; }
  find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l
}

live_image_count() {
  docker images -aq 2>/dev/null | wc -l
}

daemon_is_blind() {
  [ "$(disk_image_count)" -gt 0 ] && [ "$(live_image_count)" -eq 0 ]
}

install_dropin

if ! mountpoint -q "$DOCKER_ROOT"; then
  # Restarting would just re-init an empty store on the bare dir. Needs a human.
  log "ERROR: $DOCKER_ROOT is NOT mounted — refusing to touch docker (pool import problem?)"
  exit 1
fi

if ! daemon_is_blind; then
  log "ok: docker sees $(live_image_count) images, $(disk_image_count) on disk — view is sane"
  exit 0
fi

log "HEAL: docker reports 0 images but $(disk_image_count) exist on disk — daemon started before the data-root was mounted; restarting docker"
systemctl restart docker

# Give the daemon time to come back and re-read the mounted dataset.
i=0
while [ "$i" -lt 60 ]; do
  if docker info >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if daemon_is_blind; then
  log "ERROR: still blind after restart ($(live_image_count) live / $(disk_image_count) on disk) — manual fix needed (see runbook)"
  exit 1
fi

log "recovered: docker restarted, now sees $(live_image_count) images"
exit 0
