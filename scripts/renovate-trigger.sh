#!/bin/sh
# Dispatch the Renovate run every 5 min across 05:00-05:55 Vienna: GitHub's cron
# runs late and Renovate merges one PR per run. Docs: docs/runbooks/setup-operations/renovate-trigger.md
set -eu

REPO="drizzelat/NAS"
WORKFLOW="renovate.yml"
REF="main"

# Fine-grained PAT, Actions read+write on this repo only. Never in git: a
# root-only 0600 file on the host, or the env override.
TOKEN_FILE="${RENOVATE_TRIGGER_TOKEN_FILE:-/root/.config/renovate-trigger.token}"
LOG=/var/log/renovate-trigger.log

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
