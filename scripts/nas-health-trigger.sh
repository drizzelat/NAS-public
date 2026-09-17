#!/bin/sh
# Dispatch the nightly health check at 06:30 Vienna — GitHub's own `schedule:` cron
# is hours late. Docs: docs/runbooks/setup-operations/nas-health-check.md
set -eu

REPO="drizzelat/NAS"
WORKFLOW="nas-health-check.yml"
REF="main"

# Same fine-grained PAT as renovate-trigger.sh (Actions read+write, this repo).
# Never in git: a root-only 0600 file on the host, or the env override.
TOKEN_FILE="${RENOVATE_TRIGGER_TOKEN_FILE:-/root/.config/renovate-trigger.token}"
LOG=/var/log/nas-health-trigger.log

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

# --fail-with-body would be cleaner but needs curl >=7.76; capture status by hand.
status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $token" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
  -d "{\"ref\":\"$REF\"}")" || {
    echo "$now ERROR: curl failed to reach GitHub"
    exit 1
  }

# workflow_dispatch returns 204 No Content on success.
if [ "$status" = "204" ]; then
  echo "$now dispatched $WORKFLOW ($REF)"
else
  echo "$now ERROR: dispatch got HTTP $status (expected 204)"
  exit 1
fi
