#!/usr/bin/env bash
# Layer 4: merge cleared PRs in the 05:00 window. A merge that deploys ends the run; the
# deploy's completion starts the next one (workflow_run chain), so nothing polls and bills.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

set -uo pipefail   # NOT -e: a refused merge must not go red.
# shellcheck source=scripts/review/soak.sh
. "$(dirname "$0")/soak.sh"
# shellcheck source=scripts/review/approval.sh
. "$(dirname "$0")/approval.sh"

# GitHub cron is UTC and the window is Berlin local, so ask the clock.
hour=$(TZ=Europe/Berlin date +%H)
if [ "$IGNORE_WINDOW" != "true" ] && [ "$hour" != "05" ]; then
  echo "Berlin hour is $hour — outside the 05:00-06:00 window, nothing to do."
  exit 0
fi
if [ -z "${MERGE_TOKEN:-}" ]; then
  echo "::warning::no merge token — the Renovate App secrets are unset or the mint step failed; nothing can be merged."
  exit 0
fi

# ONE DEPLOY AT A TIME: GitHub keeps a single PENDING run per concurrency group, so
# back-to-back merges cancel the middle deploys before they start. A run that finds a
# deploy in flight stops, so a second trigger cannot fork the chain.
busy=$(gh api "repos/$REPO/actions/workflows/deploy-stacks.yml/runs?per_page=20" \
         --jq '[.workflow_runs[] | select(.status == "queued" or .status == "in_progress")] | length' \
         2>"$RUNNER_TEMP/gh.err") || {
  echo "::warning::could not read the deploy-stacks runs — merging nothing. gh said: $(tr '\n' ' ' < "$RUNNER_TEMP/gh.err")"
  exit 0
}
if [ "${busy:-0}" != "0" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "$busy deploy-stacks run(s) in flight — a real sweep would stop here; the dry run goes on."
  else
    echo "$busy deploy-stacks run(s) in flight — merging nothing; the next sweep starts when it finishes or tomorrow."
    exit 0
  fi
fi

# A chained run only continues from the tip it was started for: a later push (a revert,
# a hand merge) means the deploy it follows is no longer the whole story.
if [ "${GITHUB_EVENT_NAME:-}" = "workflow_run" ]; then
  tip=$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha 2>"$RUNNER_TEMP/gh.err") || {
    echo "::warning::could not read main's tip — merging nothing. gh said: $(tr '\n' ' ' < "$RUNNER_TEMP/gh.err")"
    exit 0
  }
  if [ "$tip" != "${CHAIN_SHA:-}" ]; then
    echo "main moved on (${tip:0:7}, the deploy was of ${CHAIN_SHA:0:7}) — merging nothing."
    exit 0
  fi
fi

open=$(gh pr list --repo "$REPO" --state open --limit 100 \
         --json number,headRefName,headRefOid,isDraft 2>/dev/null) || open='[]'
merged=0

while read -r pr; do
  [ -n "$pr" ] || continue
  num=$(jq -r .number     <<<"$pr")
  head=$(jq -r .headRefOid <<<"$pr")
  draft=$(jq -r .isDraft   <<<"$pr")
  [ "$draft" = "false" ] || { echo "#$num: draft — skipped."; continue; }

  # THREE EXPLICIT REST READS, NOT `gh pr view --json statusCheckRollup` — that
  # wrapper's GraphQL needs permissions this job lacks. NEVER send them to /dev/null.

  # 1. Mergeability. GitHub computes it lazily and answers null on the first read,
  # so ask again rather than losing the PR until the next sweep.
  prj=""; mergeable=null; mstate=unknown; err=""
  for _ in 1 2 3; do
    prj=$(gh api "repos/$REPO/pulls/$num" 2>"$RUNNER_TEMP/gh.err") || prj=""
    err=$(tr '\n' ' ' < "$RUNNER_TEMP/gh.err")
    [ -n "$prj" ] || break
    # `//` is no good here: `false // x` takes the branch. tostring keeps them distinct.
    mergeable=$(jq -r '.mergeable | tostring' <<<"$prj")
    mstate=$(jq -r '.mergeable_state // "unknown"' <<<"$prj")
    [ "$mergeable" = "null" ] || break
    sleep 5
  done
  if [ -z "$prj" ]; then
    echo "::warning::#$num: could not read the PR — skipped. gh said: ${err:-(no output)}"
    continue
  fi

  # 2. The verdict — a commit status, so the combined-status endpoint.
  review=$(gh api "repos/$REPO/commits/$head/status" 2>"$RUNNER_TEMP/gh.err" \
             | jq -r --arg p "$APPROVED_PREFIX" '[.statuses[] | select(.context == "renovate-review")
                   | if ((.description // "") | startswith($p)) then "approved" else .state end]
                   | first // "MISSING"') || review=""
  if [ -z "$review" ]; then
    echo "::warning::#$num: could not read the renovate-review status — skipped. gh said: $(tr '\n' ' ' < "$RUNNER_TEMP/gh.err")"
    continue
  fi
  case "$review" in
    success) ;;
    MISSING)
      # Branch predates this workflow, or was force-pushed and the re-review is pending.
      echo "#$num: no renovate-review status on $head — skipped (re-review with: gh workflow run renovate-pr-review.yml -f pr=$num)."
      continue ;;
    approved)
      echo "#$num: the owner approved it by hand — merge it yourself."; continue ;;
    pending)
      echo "#$num: renovate-review is still pending — skipped."; continue ;;
    *)
      echo "#$num: renovate-review=$review — the review did not clear it."; continue ;;
  esac

  # The soak: Renovate has no release date for most registries, so the sweep dates the images itself.
  if ! youngest=$(pr_youngest_image "$num" "$head"); then
    echo "::warning::#$num: could not date its images — held, not merged."
    continue
  fi
  if [ "$youngest" != none ] && [ $(( ($(date -u +%s) - youngest) / 3600 )) -lt "$SOAK_HOURS" ]; then
    echo "#$num: newest image built $(( ($(date -u +%s) - youngest) / 3600 ))h ago — soaking until ${SOAK_HOURS}h."
    continue
  fi

  # 3. Check runs and commit statuses are different resources on the same commit,
  # so read both.
  runs=$(gh api "repos/$REPO/commits/$head/check-runs" --paginate \
           --jq '.check_runs[] | "\(.name)=\(.conclusion // "pending")"' \
           2>"$RUNNER_TEMP/gh.err") || runs=""
  if [ -z "$runs" ]; then
    echo "::warning::#$num: could not read the check runs — skipped. gh said: $(tr '\n' ' ' < "$RUNNER_TEMP/gh.err")"
    continue
  fi
  statuses=$(gh api "repos/$REPO/commits/$head/status" \
               --jq '.statuses[] | "\(.context)=\(.state)"' 2>/dev/null) || statuses=""

  failed=$(printf '%s\n%s\n' "$runs" "$statuses" \
             | grep -E '=(failure|timed_out|cancelled|action_required|error|stale)$' \
             | cut -d= -f1 | paste -sd', ' -) || failed=""
  # `validate` (compose-validate) is a required check on main.
  validate=$(grep -m1 '^validate=' <<<"$runs" | cut -d= -f2) || validate=""

  if [ -n "$failed" ]; then
    echo "::warning::#$num: failing checks ($failed) — not merging."
    continue
  fi
  if [ "$mergeable" != "true" ] || [ "${validate:-MISSING}" != "success" ]; then
    echo "#$num: mergeable=$mergeable ($mstate) validate=${validate:-MISSING} — not merging."
    continue
  fi

  # Does the merge deploy? Only stacks/** starts deploy-stacks; any other PR (an Actions pin) has
  # no deploy to chain from, so the sweep carries on. Unreadable counts as a deploy: stop, never race.
  if files=$(gh api "repos/$REPO/pulls/$num/files" --paginate --jq '.[].filename' 2>"$RUNNER_TEMP/gh.err"); then
    grep -q '^stacks/' <<<"$files" && deploys=true || deploys=false
  else
    echo "::warning::#$num: could not list its files — treating it as a deploy. gh said: $(tr '\n' ' ' < "$RUNNER_TEMP/gh.err")"
    deploys=true
  fi

  # Dry run exercises the read path at any hour without redeploying. Run one after
  # touching this job or its permissions.
  if [ "$DRY_RUN" = "true" ]; then
    if [ "$deploys" = "true" ]; then
      echo "#$num: WOULD MERGE (dry run) — touches stacks/, a real sweep ends here and chains the next on the deploy."
    else
      echo "#$num: WOULD MERGE (dry run) — no stacks/ change, a real sweep carries on."
    fi
    merged=$((merged + 1))
    continue
  fi

  # --match-head-commit: refuse if the branch moved since the checks above.
  if GH_TOKEN="$MERGE_TOKEN" gh pr merge "$num" --repo "$REPO" --merge \
       --delete-branch --match-head-commit "$head"; then
    merged=$((merged + 1))
    echo "merged #$num"
    if [ "$deploys" = "true" ]; then
      echo "#$num starts a deploy — stopping; its completion starts the next sweep run."
      break
    fi
  else
    echo "::warning::#$num: merge refused — merge it by hand."
  fi
done < <(jq -c '.[] | select(.headRefName | startswith("renovate/"))' <<<"$open")

if [ "$DRY_RUN" = "true" ]; then
  echo "$merged PR(s) WOULD have merged in this sweep — dry run, nothing was merged."
else
  echo "merged $merged PR(s) in this sweep."
fi
