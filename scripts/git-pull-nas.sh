#!/bin/sh
# Fast-forward the on-NAS clone at /mnt/apps/scripts/nas every 15 min. The running
# copy lives OUTSIDE the clone so a bad commit cannot break the updater.
set -eu
export HOME=/root

REPO=/mnt/apps/scripts/nas
LOG=/var/log/nas-repo-pull.log
LOCK=/tmp/nas-repo-pull.lock

exec >>"$LOG" 2>&1

# Single-instance guard so a slow fetch cannot overlap the next tick.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "$(date '+%F %T') skip: another run holds the lock"; exit 0; }
fi

before="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo none)"
git -C "$REPO" fetch --quiet origin main
git -C "$REPO" reset --quiet --hard origin/main
after="$(git -C "$REPO" rev-parse --short HEAD)"

if [ "$before" != "$after" ]; then
  echo "$(date '+%F %T') updated $before -> $after"
fi
