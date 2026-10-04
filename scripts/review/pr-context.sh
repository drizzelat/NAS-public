#!/usr/bin/env bash
# Resolve the PR number/head/branch and whether it touches a stack compose.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

set -euo pipefail
if [ "$EVENT" = "workflow_dispatch" ]; then
  number="$INPUT_PR"
  # The head commit is not in this checkout — the PR ref has it.
  git fetch -q origin "refs/pull/$number/head"
  head=$(git rev-parse FETCH_HEAD)
  base=$(gh pr view "$number" --json baseRefOid --jq .baseRefOid)
  labels=$(gh pr view "$number" --json labels --jq '[.labels[].name] | join(",")')
  headref=$(gh pr view "$number" --json headRefName --jq .headRefName)
else
  number="$EVENT_PR"; base="$EVENT_BASE"; head="$EVENT_HEAD"; labels="$EVENT_LABELS"
  headref="$EVENT_HEADREF"
fi
# Diff from the merge base, not the base tip: if `main` moved ahead, base..head
# renders those commits as reversions and invents image changes.
base=$(git merge-base "$base" "$head")
echo "pr=$number"       >> "$GITHUB_OUTPUT"
echo "base=$base"       >> "$GITHUB_OUTPUT"
echo "head=$head"       >> "$GITHUB_OUTPUT"
echo "headref=$headref" >> "$GITHUB_OUTPUT"
# Labels gate nothing now, but say which renovate.json rule matched.
echo "PR #$number  $base..$head  [$labels]  $headref"
