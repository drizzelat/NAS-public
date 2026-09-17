#!/usr/bin/env bash
# Alarm when a cleared PR sits unmerged past MAX_AGE_HOURS — silence otherwise looks like a dead sweep.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

set -uo pipefail
now=$(date -u +%s)
stale=""

open=$(gh pr list --repo "$REPO" --state open --limit 100 \
         --json number,headRefName,headRefOid,isDraft 2>/dev/null) || open='[]'

while read -r pr; do
  [ -n "$pr" ] || continue
  num=$(jq -r .number      <<<"$pr")
  head=$(jq -r .headRefOid <<<"$pr")
  [ "$(jq -r .isDraft <<<"$pr")" = "false" ] || continue

  # The combined status keeps the newest per context; created_at = when cleared.
  st=$(gh api "repos/$REPO/commits/$head/status" \
         --jq '.statuses[] | select(.context == "renovate-review") | "\(.state) \(.created_at)"' \
         2>/dev/null | head -n 1)
  [ -n "$st" ] || continue
  set -- $st
  [ "$1" = "success" ] || continue
  granted=$(date -u -d "$2" +%s 2>/dev/null) || continue
  age=$(( (now - granted) / 3600 ))
  [ "$age" -gt "$MAX_AGE_HOURS" ] || continue

  files=$(gh api "repos/$REPO/pulls/$num/files" --paginate --jq '.[].filename' 2>/dev/null) || files=""
  # Not a stack PR: Renovate's own automerge owns it, not the sweep.
  grep -q '^stacks/.*/docker-compose\.yml$' <<<"$files" || continue
  skip=""
  for s in $MERGE_SKIP; do
    # `if`, not `&&`: the shell has -e set and a failing AND-list would kill the job.
    if grep -qx "stacks/$s/docker-compose.yml" <<<"$files"; then
      skip="$s"; break
    fi
  done
  [ -z "$skip" ] || { echo "#$num: MERGE_SKIP ($skip) — cleared-but-unmerged by design."; continue; }

  added=$(gh api "repos/$REPO/pulls/$num/files" --paginate --jq '.[].patch // ""' 2>/dev/null \
            | grep -E '^\+[[:space:]]*image:' || true)
  hit=""
  for img in $MERGE_SKIP_IMAGES; do
    if printf '%s\n' "$added" | grep -qE "image:[[:space:]]*(docker\.io/library/)?${img}[:@]"; then
      hit="$img"; break
    fi
  done
  [ -z "$hit" ] || { echo "#$num: stateful image ($hit) — cleared-but-unmerged by design."; continue; }

  stale="$stale #$num (cleared ${age}h ago)"
done < <(jq -c '.[] | select(.headRefName | startswith("renovate/"))' <<<"$open")

if [ -n "$stale" ]; then
  echo "::error::The merge sweep has not acted on cleared PRs:$stale"
  echo "Every one of these has a green renovate-review status and should have"
  echo "merged in an 05:00-06:00 Berlin window. Check that the window-merge job"
  echo "is actually running in-window: the TrueNAS cron (scripts/merge-sweep-trigger.sh)"
  echo "is the primary trigger, GitHub's own schedule: only a fallback."
  exit 1
fi
echo "No stale clearances — every cleared PR was merged within ${MAX_AGE_HOURS}h."
