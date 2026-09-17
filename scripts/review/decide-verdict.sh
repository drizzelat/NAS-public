#!/usr/bin/env bash
# Layer 3: combine delta + risk into the renovate-review status and automerge flag.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

set -uo pipefail
automerge=false
gate=success
case "$HEADREF" in
  renovate/*) ;;
  # A dispatch aimed at a hand-written PR — nothing here applies; stay green.
  *) reason="not a renovate/* branch" ;;
esac
if [ -z "${reason:-}" ]; then
  if [ "$STACK" != "true" ]; then
    # No compose image moved (github-actions, stacks/caddy/Dockerfile inputs): nothing to
    # assess. The sweep merges these on the green status unless Renovate already has.
    reason="no stack compose image changed — nothing to assess"
  elif [ "$DELTA_VERDICT" = "NOOP" ]; then
    automerge=true
    reason="the image this host pulls is byte-identical"
  elif [ "$DELTA_VERDICT" = "UNKNOWN" ]; then
    reason="the image delta could not be resolved"; gate=failure
  elif [ "$HAVE_TOKEN" != "true" ]; then
    reason="no Claude secret, so nothing assessed the upstream change"; gate=failure
  elif [ "$RISK" = "LOW" ]; then
    automerge=true
    reason="RISK: LOW"
  elif [ "$RISK" = "REVIEW" ]; then
    reason="RISK: REVIEW"; gate=failure
  else
    reason="the agent produced no usable verdict"; gate=failure
  fi
fi
echo "automerge=$automerge" >> "$GITHUB_OUTPUT"
echo "gate=$gate"           >> "$GITHUB_OUTPUT"
echo "reason=$reason"       >> "$GITHUB_OUTPUT"
echo "verdict: status=$gate automerge=$automerge ($reason)"
