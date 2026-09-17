#!/bin/sh
# Dispatch the daily freshness checks of both self-built Tor bridge images: GitHub's schedule runs
# late and is often dropped. Docs: docs/runbooks/setup-operations/renovate-trigger.md#tor-bridge-image-trigger
set -eu

REPO="drizzelat/NAS"
WORKFLOWS="build-webtunnel-image.yml build-obfs4-image.yml"
REF="main"

# Fine-grained PAT, Actions read+write on this repo only. Never in git: a
# root-only 0600 file on the host, or the env override.
TOKEN_FILE="${RENOVATE_TRIGGER_TOKEN_FILE:-/root/.config/renovate-trigger.token}"
LOG=/var/log/tor-bridge-image-trigger.log

exec >>"$LOG" 2>&1

now="$(date '+%F %T %Z')"

if [ -n "${RENOVATE_TRIGGER_TOKEN:-}" ]; then
  token="$RENOVATE_TRIGGER_TOKEN"
elif [ -r "$TOKEN_FILE" ]; then
  token="$(cat "$TOKEN_FILE")"
else
  echo "$now ERROR: no token (set RENOVATE_TRIGGER_TOKEN or create $TOKEN_FILE)"
  exit 1
fi

# One failed dispatch must not skip the other image; the exit code still reports it.
failed=0
for workflow in $WORKFLOWS; do
  # --fail-with-body would be cleaner but needs curl >=7.76; capture status by hand.
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $token" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO/actions/workflows/$workflow/dispatches" \
    -d "{\"ref\":\"$REF\"}")" || status="curl-failed"

  # workflow_dispatch returns 204 No Content on success.
  if [ "$status" = "204" ]; then
    echo "$now dispatched $workflow ($REF)"
  else
    echo "$now ERROR: dispatch of $workflow got $status (expected HTTP 204)"
    failed=1
  fi
done
exit "$failed"
