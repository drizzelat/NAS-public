#!/bin/sh
# Dead-man's switch to healthchecks.io — an alerter NOT operated here, so "everything
# we run is down" is detectable. Docs: docs/runbooks/setup-operations/external-heartbeat.md

set -u

# Host-side config, never the repo: the ping URL is effectively a secret (anyone holding
# it can keep a dead host looking alive).
URL_FILE="${HC_URL_FILE:-/root/.config/healthchecks-ping.url}"

# Optional: a container whose absence means this host is not doing its job. Its name
# lives beside the URL so one script serves every host unchanged.
GUARD_FILE="${HC_GUARD_FILE:-/root/.config/healthchecks-guard.container}"

[ -r "$URL_FILE" ] || { echo "healthchecks-ping: no URL at $URL_FILE" >&2; exit 1; }
URL="$(cat "$URL_FILE")"
[ -n "$URL" ] || { echo "healthchecks-ping: $URL_FILE is empty" >&2; exit 1; }

# Pick whichever docker invocation works here; the NAS runs this as root, the VPS
# hosts need sudo because `ubuntu` is not in the docker group.
docker_cmd() {
  if docker ps >/dev/null 2>&1; then docker "$@"
  else sudo -n docker "$@"
  fi
}

state="ok"
detail="host alive"

if [ -r "$GUARD_FILE" ]; then
  guard="$(cat "$GUARD_FILE")"
  if [ -n "$guard" ]; then
    if ! docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "$guard"; then
      state="fail"
      detail="guard container '$guard' is not running"
    else
      detail="guard container '$guard' running"
    fi
  fi
fi

# /fail flips the check red immediately instead of waiting for the grace period to
# lapse — a running-but-broken host is worse than a silent one.
[ "$state" = ok ] || URL="${URL%/}/fail"

# Whole retry budget must fit inside the 1-minute cron cadence: 10s x 2 tries plus
# one 3s backoff is ~23s worst case, so runs cannot pile up on a slow uplink.
printf '%s\n' "$detail" | curl -fsS -m 10 --retry 2 --retry-delay 3 \
  --data-binary @- "$URL" >/dev/null 2>&1 \
  || { echo "healthchecks-ping: could not reach healthchecks.io" >&2; exit 1; }

echo "healthchecks-ping: $state — $detail"
