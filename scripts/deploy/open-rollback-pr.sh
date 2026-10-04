#!/usr/bin/env bash
# Roll back unhealthy stacks by PR: restore each stack's folder from the pre-push commit on a branch,
# open a PR, and squash-merge it once its required checks pass. The merge push then deploys the
# restored compose through deploy-stacks like any other change. Runs on a GitHub-hosted runner; the
# self-hosted runner only names the stacks and holds nothing that writes main.
# Docs: docs/runbooks/setup-operations/deploy-stacks.md#health-and-rollback
#
# Env: REPO, EVENT, BEFORE, AFTER (from the push event, never from the runner), REQUESTED (stack names
# from verify-healthy.sh, untrusted), GH_TOKEN (reads), MERGE_TOKEN (branch push, PR, merge), RUN_URL.
# DRY_RUN=true runs every gate and builds the commit, then stops before the push. With DRY_RUN and
# no BEFORE, the push under test is main's last commit touching the first REQUESTED stack.

set -euo pipefail
# shellcheck source=scripts/komodo/lib.sh
. "$(dirname "$0")/../komodo/lib.sh"
CHECK_WAIT=900   # seconds to wait for validate + renovate-review on the PR head
GAP=15
ZERO=0000000000000000000000000000000000000000
SUBJECT_RE='^revert\(deploy\): roll back unhealthy stack\(s\): '

git fetch --quiet origin main
if [ "${DRY_RUN:-false}" = true ] && [ -z "${BEFORE:-}" ]; then
  first=$(printf '%s' "$REQUESTED" | awk '{print $1}')
  AFTER=$(git log -1 --format=%H origin/main -- "stacks/$first/")
  [ -n "$AFTER" ] || { echo "::error::no commit on main touches stacks/$first"; exit 1; }
  BEFORE=$(git rev-parse "$AFTER^")
  echo "dry run: rehearsing the push $BEFORE..$AFTER"
elif [ "$EVENT" != push ] || [ -z "${BEFORE:-}" ] || [ "$BEFORE" = "$ZERO" ]; then
  # A dispatched stack is never rolled back: the repo pin is the intended state.
  echo "::error::rollback needs a push with a pre-push commit (event $EVENT, before '${BEFORE:-}') — nothing rolled back"
  exit 1
fi

# Rolling back a rollback would re-apply the bad change. A revert that comes up unhealthy needs a human.
if git log -1 --format=%s "$AFTER" | grep -qE "$SUBJECT_RE"; then
  echo "::error::the unhealthy push is itself an auto-rollback ($AFTER) — not reverting it. Fix the stack by hand"
  exit 1
fi

# Candidates are checked against the push itself: the runner can only pick among the stacks this
# push changed, and only restore them to the pre-push state of main.
pushed=$(git diff --no-renames --name-only "$BEFORE" "$AFTER" -- 'stacks/**' | cut -d/ -f2 | sort -u)
OWNED=$(komodo_owned | xargs)
git checkout --quiet -B rollback origin/main
restored=""
for stack in $(printf '%s' "$REQUESTED" | tr ' ,' '\n\n' | sed '/^$/d' | sort -u); do
  if ! printf '%s\n' "$pushed" | grep -qxF -- "$stack"; then
    echo "::error::'$stack' was not changed by $BEFORE..$AFTER — not rolling it back"; continue
  fi
  case " $OWNED " in *" $stack "*) ;; *)
    echo "::error::'$stack' is not in komodo/owned-stacks — not rolling it back"; continue;;
  esac
  f="stacks/$stack/"
  if [ "$(git rev-parse "origin/main:$f" 2>/dev/null)" != "$(git rev-parse "$AFTER:$f" 2>/dev/null)" ]; then
    echo "::warning::'$stack' changed on main since $AFTER — a newer push owns it, not rolling back"; continue
  fi
  if ! git cat-file -e "$BEFORE:$f" 2>/dev/null; then
    echo "::error::'$stack' did not exist at $BEFORE (a new stack) — nothing to roll back to"; continue
  fi
  # Loop breaker: two auto-rescues max, else main flaps revert/re-bump nightly with nobody watching.
  # Counts the squash subjects " (#N)" and the older direct pushes " [skip ci]".
  rb_count=$(git log --since='7 days ago' --format=%s origin/main -- "$f" \
             | sed -nE "s/${SUBJECT_RE}(.*)( \\[skip ci\\]| \\(#[0-9]+\\))$/\\1/p" \
             | tr ' ' '\n' | grep -cxF -- "$stack") || rb_count=0
  if [ "${rb_count:-0}" -ge 2 ]; then
    echo "::error::'$stack' was auto-rolled-back $rb_count times in the last 7 days and is failing again — refusing to flap main. Hold the pin in Renovate (or fix the stack) by hand"
    continue
  fi
  # Remove first: a checkout alone would keep files the bad push added.
  git rm -r --quiet -- "$f"
  git checkout "$BEFORE" -- "$f"
  restored="$restored $stack"
done
restored=$(echo $restored | xargs)
[ -n "$restored" ] || { echo "::error::nothing to roll back"; exit 1; }
if git diff --cached --quiet; then
  echo "::error::restoring $restored produced no diff (already at the pre-push state?)"; exit 1
fi

title="revert(deploy): roll back unhealthy stack(s): $restored"
body="Auto-rollback from deploy-stacks: $restored came up unhealthy after $AFTER and is restored to $BEFORE.

Failed run: $RUN_URL

Merged automatically once \`validate\` and \`renovate-review\` pass. The merge deploys the restored compose through deploy-stacks, with its health check. Nothing written to a host path or a database is undone."
git -c user.name=nas-deploy-bot -c user.email=deploy@nas.invalid commit --quiet -m "$title" -m "$body"
git --no-pager show --stat --format='%s' HEAD
if [ "${DRY_RUN:-false}" = true ]; then
  echo "dry run: would push rollback/${GITHUB_RUN_ID:-local}, open a PR and squash-merge it once checks pass"
  exit 0
fi

branch="rollback/${GITHUB_RUN_ID}"
git push --quiet origin "HEAD:refs/heads/$branch"
pr=$(GH_TOKEN="$MERGE_TOKEN" gh api "repos/$REPO/pulls" -f title="$title" -f head="$branch" -f base=main \
       -f body="$body" --jq '.number')
head=$(git rev-parse HEAD)
echo "opened #$pr on $branch ($head)"

# Required checks: the `validate` check run and the `renovate-review` status (a passthrough on a
# non-renovate/ branch). REST reads with GH_TOKEN, never gh's GraphQL (checks + statuses scopes).
state=""
for _ in $(seq 1 $((CHECK_WAIT / GAP))); do
  sleep "$GAP"
  v=$(gh api "repos/$REPO/commits/$head/check-runs?check_name=validate" \
        --jq '[.check_runs[] | .conclusion // "pending"] | first // "pending"') || v=pending
  r=$(gh api "repos/$REPO/commits/$head/status" \
        --jq '[.statuses[] | select(.context == "renovate-review") | .state] | first // "pending"') || r=pending
  case "$v/$r" in
    success/success) state=ok; break ;;
    pending/*|*/pending) ;;
    *) state="validate=$v renovate-review=$r"; break ;;
  esac
done
if [ "$state" != ok ]; then
  echo "::error::rollback PR #$pr not merged: checks ${state:-still pending after ${CHECK_WAIT}s}. Prod is still on the unhealthy change; merge or close #$pr by hand"
  exit 1
fi
if ! GH_TOKEN="$MERGE_TOKEN" gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=squash \
       -f sha="$head" -f commit_title="$title (#$pr)" -f commit_message="$body" >/dev/null; then
  echo "::error::rollback PR #$pr passed its checks but the merge failed. Prod is still on the unhealthy change; merge #$pr by hand"
  exit 1
fi
echo "::warning::rolled back $restored through #$pr; the merge push deploys it"
