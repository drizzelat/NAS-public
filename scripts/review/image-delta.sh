#!/usr/bin/env bash
# Layer 1: deterministic registry image delta. Emits NOOP / CHANGED / UNKNOWN.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

set -uo pipefail   # NOT -e: a registry hiccup must not fail the job.
report="$RUNNER_TEMP/delta.md"
if ! bash scripts/renovate-image-delta.sh "$BASE" "$HEAD" > "$report" 2>"$RUNNER_TEMP/delta.err"; then
  {
    echo "Image delta could not be resolved — inspect the digests by hand."
    echo
    echo '```'
    tail -n 20 "$RUNNER_TEMP/delta.err"
    echo '```'
    echo
    echo "DELTA: UNKNOWN"
  } > "$report"
fi
cat "$report"
verdict=$(grep -E '^DELTA: ' "$report" | tail -n 1 | cut -d' ' -f2)
echo "verdict=${verdict:-UNKNOWN}" >> "$GITHUB_OUTPUT"
echo "report=$report" >> "$GITHUB_OUTPUT"

# github-actions bumps ride `renovate/*` too and the delta script calls them a
# NO-OP. They touch no stack and Renovate merges them itself — do not act.
if [ -n "$(git diff --name-only "$BASE" "$HEAD" -- 'stacks/**/docker-compose.yml')" ]; then
  echo "stack=true" >> "$GITHUB_OUTPUT"
else
  echo "stack=false" >> "$GITHUB_OUTPUT"
fi
