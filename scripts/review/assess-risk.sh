#!/usr/bin/env bash
# Layer 2: the Claude risk pass over the image delta. Emits RISK: LOW / REVIEW.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

set -uo pipefail   # NOT -e: an agent failure must not fail the job.
out="$RUNNER_TEMP/agent.md"

# The agent never sees env var values, so copy the delta report INTO the working
# directory (Read is scoped to it) and interpolate every other fact literally.
cp "$DELTA_REPORT" "$GITHUB_WORKSPACE/delta-report.md"

# No Write/Edit: stdout is the whole deliverable. Bash for git diff, WebFetch for changelogs.
claude -p "Follow the instructions in .github/renovate-pr-review.md exactly and produce the report it specifies.

This is PR #${PR}. The image delta report is the file delta-report.md in the working directory — read it first. The PR diff is: git diff ${BASE_SHA} ${HEAD_SHA} -- 'stacks/**/docker-compose.yml'" \
  --model claude-sonnet-5 \
  --allowedTools "Read,Glob,Grep,WebFetch,Bash(git diff:*),Bash(git log:*)" \
  --output-format json > "$RUNNER_TEMP/claude.json"
rc=$?
rm -f "$GITHUB_WORKSPACE/delta-report.md"

jq -r '.result // empty' "$RUNNER_TEMP/claude.json" > "$out" 2>/dev/null || : > "$out"
if [ ! -s "$out" ]; then
  printf 'Agent produced no report (exit %s) — review by hand.\n' "$rc" > "$out"
fi
# Share of a Claude Pro 5h window, in input-token equivalents (cache-write 1.25x,
# cache-read 0.1x, output 5x). Same weighting as nas-health-check — keep in step.
budget=${CLAUDE_SESSION_TOKEN_BUDGET:-}
case "$budget" in ''|*[!0-9]*|0) budget=1500000 ;; esac
usage=$(jq -r --argjson budget "$budget" '
  (.usage.input_tokens // 0)                  as $in
  | (.usage.cache_read_input_tokens // 0)     as $cr
  | (.usage.cache_creation_input_tokens // 0) as $cw
  | (.usage.output_tokens // 0)               as $out
  | (($in + $cw * 1.25 + $cr * 0.1 + $out * 5) / $budget * 1000 | round / 10) as $pct
  | "\($in) in, \($out) out · \(.num_turns) turns · $\(.total_cost_usd) · ~\($pct)% of a 5h Pro session"
' "$RUNNER_TEMP/claude.json" 2>/dev/null || echo "unavailable")

# Read the verdict pessimistically: a REVIEW anywhere wins, and anything that is
# not an unambiguous LOW is NONE.
last=$(grep -E '^RISK: ' "$out" | tail -n 1 | sed 's/[[:space:]]*$//')
if grep -qE '^RISK: REVIEW[[:space:]]*$' "$out"; then
  risk=REVIEW
elif [ "$last" = "RISK: LOW" ]; then
  risk=LOW
else
  risk=NONE
fi

cat "$out"
echo "risk=$risk" >> "$GITHUB_OUTPUT"
echo "report=$out" >> "$GITHUB_OUTPUT"
echo "usage=$usage" >> "$GITHUB_OUTPUT"
