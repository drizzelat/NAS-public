#!/bin/sh
# Dispatch the Renovate run once a day at 04:15 local time: GitHub's cron runs late
# and drops events, so the host cron is the only trigger. Docs: docs/runbooks/setup-operations/renovate-trigger.md
set -eu

REPO="drizzelat/NAS"
WORKFLOW="renovate.yml"
REF="main"

# Fine-grained PAT, Actions read+write on this repo only. Never in git: a
# root-only 0600 file on the host, or the env override.
TOKEN_FILE="${RENOVATE_TRIGGER_TOKEN_FILE:-/root/.config/renovate-trigger.token}"
LOG=/var/log/renovate-trigger.log

# The host cron is Renovate's only trigger, so a dead cron or an expired token
# must not be silent. Kuma push monitor pinged on success (a missing ping catches
# the cron not running); failure mails like pg-dump-backup.sh. Host file, not git.
PUSH_URL_FILE="/root/.config/renovate-trigger-kuma-push.url"

exec >>"$LOG" 2>&1

now="$(date '+%F %T %Z')"

fail() {  # $1 = message; log, mail, exit non-zero
  echo "$now ERROR: $1"
  to="$(midclt call mail.config 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("fromemail") or "")' 2>/dev/null || true)"
  [ -n "$to" ] && MSG="$1" TO="$to" python3 -c '
import os, json, subprocess
payload = json.dumps({"subject": "[NAS] Renovate trigger FAILED",
                      "text": "renovate-trigger.sh on %s: %s\nNo Renovate run was dispatched. Log: /var/log/renovate-trigger.log\n" % (os.uname().nodename, os.environ["MSG"]),
                      "to": [os.environ["TO"]]})
subprocess.run(["midclt", "call", "mail.send", payload],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
' 2>/dev/null || true
  exit 1
}

if [ -n "${RENOVATE_TRIGGER_TOKEN:-}" ]; then
  token="$RENOVATE_TRIGGER_TOKEN"
elif [ -r "$TOKEN_FILE" ]; then
  token="$(cat "$TOKEN_FILE")"
else
  fail "no token (set RENOVATE_TRIGGER_TOKEN or create $TOKEN_FILE)"
fi

# --fail-with-body would be cleaner but needs curl >=7.76; capture status by hand.
status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $token" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
  -d "{\"ref\":\"$REF\"}")" || fail "curl failed to reach GitHub"

# workflow_dispatch returns 204 No Content on success.
if [ "$status" = "204" ]; then
  echo "$now dispatched $WORKFLOW ($REF)"
else
  fail "dispatch got HTTP $status (expected 204)"
fi

if [ -r "$PUSH_URL_FILE" ]; then
  url="$(cat "$PUSH_URL_FILE")"
  [ -n "$url" ] && curl -fsS -m 15 "$url" >/dev/null 2>&1 || true
fi
