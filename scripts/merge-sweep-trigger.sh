#!/bin/sh
# Dispatch the Renovate merge sweep at 05:20/05:35/05:50 Vienna — GitHub's own
# `schedule:` cron is too unreliable. Docs: docs/runbooks/setup-operations/renovate-trigger.md
set -eu

REPO="drizzelat/NAS"
WORKFLOW="renovate-pr-review.yml"
REF="main"

# Same fine-grained PAT as renovate-trigger.sh (Actions read+write, this repo).
# Never in git: a root-only 0600 file on the host, or the env override.
TOKEN_FILE="${RENOVATE_TRIGGER_TOKEN_FILE:-/root/.config/renovate-trigger.token}"
LOG=/var/log/merge-sweep-trigger.log

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

# NO `inputs` block on purpose: both defaults are what this cron wants — sweep
# mode, and the run enforcing the 05:00-06:00 window itself.
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
  echo "$now dispatched $WORKFLOW sweep ($REF)"
else
  echo "$now ERROR: dispatch got HTTP $status (expected 204)"
  exit 1
fi
