#!/bin/sh
# Reclaim disk by removing UNUSED Docker images. Portable POSIX sh; runs on the
# NAS and both VPS hosts. Docs: docs/runbooks/setup-operations/docker-image-prune.md

set -eu

# Age window. Override with arg 1 or DOCKER_PRUNE_UNTIL (e.g. 720h).
UNTIL="${1:-${DOCKER_PRUNE_UNTIL:-168h}}"

LOG="${DOCKER_PRUNE_LOG:-/var/log/docker-image-prune.log}"
LOCK="/tmp/docker-image-prune.lock"

# Optional Uptime-Kuma push monitor; kept in a host file so no token is committed.
PUSH_URL_FILE="${DOCKER_PRUNE_PUSH_URL_FILE:-/root/.config/docker-image-prune-kuma-push.url}"

# Fall back to stdout where /var/log is not root-writable.
if { : >>"$LOG"; } 2>/dev/null; then
  exec >>"$LOG" 2>&1
fi

log() { echo "$(date '+%F %T') $*"; }

# Single-instance guard so a slow prune cannot overlap the next tick.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { log "skip: another run holds the lock"; exit 0; }
fi

if ! command -v docker >/dev/null 2>&1; then
  log "ERROR: docker CLI not found"
  exit 1
fi

log "prune start (until=$UNTIL)"

# -a: all unused images. -f skips the prompt only — it never force-removes an
# in-use image. The age guard keeps a rollback's old image available locally.
if ! out="$(docker image prune -af --filter "until=$UNTIL" 2>&1)"; then
  log "ERROR: docker image prune failed:"
  log "$out"
  exit 1
fi

# Echo docker's own summary (includes "Total reclaimed space").
echo "$out" | sed 's/^/    /'
reclaimed="$(echo "$out" | grep -i 'Total reclaimed space' || echo 'Total reclaimed space: 0B')"
log "prune done — $reclaimed"

# Heartbeat on success; a late ping tells Kuma the job stopped running at all.
if [ -f "$PUSH_URL_FILE" ]; then
  PUSH_URL="$(head -n1 "$PUSH_URL_FILE" | tr -d '[:space:]')"
  if [ -n "$PUSH_URL" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 10 "$PUSH_URL" >/dev/null 2>&1 || log "warn: Kuma push failed"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- -T 10 "$PUSH_URL" >/dev/null 2>&1 || log "warn: Kuma push failed"
    fi
  fi
fi

exit 0
