#!/usr/bin/env bash
# Claude review of what the next sync would publish: review.sh <stage-dir>. Exit 0 only on VERDICT: PUBLISH.
# Instructions: .github/public-mirror-review.md. Docs: docs/runbooks/setup-operations/public-mirror.md
set -uo pipefail   # NOT -e: every failure must end as a HOLD with a reason, never a silent pass.

stage=${1:?usage: review.sh <stage-dir>}
here=$(cd "$(dirname "$0")" && pwd)
instructions=$(git -C "$here" rev-parse --show-toplevel)/.github/public-mirror-review.md
max_bytes=${REVIEW_MAX_BYTES:-200000}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
summary=${GITHUB_STEP_SUMMARY:-/dev/stderr}

verdict() {   # <PUBLISH|HOLD> <reason>; report.md, if any, follows the reason
  { echo "## Public mirror review: $1"; echo; echo "$2"; echo
    [ ! -s "$work/report.md" ] || cat "$work/report.md"; } >>"$summary"
  echo "$1: $2"
  [ "$1" = PUBLISH ]
  exit
}

# Digest and action pins change every week and cannot leak anything, so their lines are dropped.
# A hunk with no other change goes, and so does a file with no hunk left.
awk '
  function end_hunk() { if (keep) body = body hunk; hunk = ""; keep = 0 }
  function end_file() {
    end_hunk()
    if (head != "" && (hunks == 0 || body != "")) printf "%s%s", head, body
    head = ""; body = ""; hunks = 0; in_hunk = 0
  }
  /^diff --git / { end_file(); head = $0 "\n"; next }
  /^@@/ { end_hunk(); in_hunk = 1; hunks++; hunk = $0 "\n"; next }
  !in_hunk { head = head $0 "\n"; next }
  /^[+-][ \t]*(- )?image:[ \t]*[^ \t]+@sha256:[0-9a-f]+[ \t]*(#.*)?$/ { next }
  /^[+-][ \t]*(- )?uses:[ \t]*[^ \t]+@[0-9a-f]+[ \t]*(#.*)?$/ { next }
  /^[+-]FROM[ \t]+[^ \t]+@sha256:[0-9a-f]+/ { next }
  /^[+-]/ { keep = 1 }
  { hunk = hunk $0 "\n" }
  END { end_file() }
' "$stage/full.diff" >"$work/filtered.diff"

[ -s "$work/filtered.diff" ] || verdict PUBLISH "Only digest and action pins changed; nothing to review."
size=$(wc -c <"$work/filtered.diff")
[ "$size" -le "$max_bytes" ] \
  || verdict HOLD "The diff is $size bytes, over the $max_bytes review limit. Read full.diff in the run's artifact yourself, then dispatch with approve_sha."
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] \
  || verdict HOLD "Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set."

{ echo "# Changed files"; echo; cat "$stage/files.txt"; echo; echo "# Diff"; echo; cat "$work/filtered.diff"; } >"$work/input"

# No tools: the diff arrives on stdin, so nothing in it can make the model read or run anything.
# Run outside the checkout, or the repo's CLAUDE.md would be loaded as instructions.
(cd "$work" && claude -p "$(cat "$instructions")" \
  --model claude-sonnet-5 \
  --tools "" \
  --max-turns 2 \
  --output-format json <"$work/input" >"$work/claude.json")
rc=$?
jq -r '.result // empty' "$work/claude.json" >"$work/report.md" 2>/dev/null || : >"$work/report.md"
usage=$(jq -r '"\(.num_turns) turns, $\(.total_cost_usd)"' "$work/claude.json" 2>/dev/null || echo "usage unavailable")

# Pessimistic, like the Renovate review: a HOLD anywhere wins; only a clean last-line PUBLISH passes.
last=$(grep -E '^VERDICT: ' "$work/report.md" | tail -n 1 | sed 's/[[:space:]]*$//')
if grep -qE '^VERDICT: HOLD' "$work/report.md"; then
  verdict HOLD "Claude found something to check ($usage, $size bytes reviewed)."
elif [ "$last" = "VERDICT: PUBLISH" ]; then
  verdict PUBLISH "Claude found nothing to hold back ($usage, $size bytes reviewed)."
else
  verdict HOLD "No usable verdict (claude exit $rc, $usage)."
fi
