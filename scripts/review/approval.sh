#!/usr/bin/env bash
# Owner approval of a red renovate-review. Sourced by decide-verdict, comment, merge-sweep, stale-alarm.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

# Status-description prefix: how the sweep and the stale alarm tell "approved by hand" from "cleared".
export APPROVED_PREFIX="approved by"

# Prints OWNER and returns 0 when OWNER's latest approve/request-changes/dismissed review of PR is an APPROVE of exactly HEAD.
approved_by() {
  local repo=$1 pr=$2 head=$3 owner=$4 last
  last=$(gh api "repos/$repo/pulls/$pr/reviews" --paginate \
    | jq -r --arg o "$owner" '.[]
        | select(.user.login == $o and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
        | "\(.state) \(.commit_id)"' \
    | tail -n 1) || return 1
  if [ "$last" = "APPROVED $head" ]; then
    printf '%s\n' "$owner"
    return 0
  fi
  case "$last" in
    "APPROVED "*) echo "approval by $owner is for ${last#APPROVED }, the head is $head — approve the current commit." >&2 ;;
  esac
  return 1
}
