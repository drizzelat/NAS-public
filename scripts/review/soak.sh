# shellcheck shell=bash
# The release-age soak for stack PRs, shared by merge-sweep.sh and stale-alarm.sh. Source it.
# Env: REPO, GH_TOKEN. Docs: docs/runbooks/setup-operations/renovate-pr-review.md → The soak

SOAK_HOURS="${SOAK_HOURS:-72}"

# pr_youngest_image <pr> <head-sha> -> epoch of the newest image the PR adds, "none" when it adds
# no image. An image whose build time cannot be read counts from the head commit, never as old.
pr_youngest_image() {
  local rows row f ref e youngest="" fallback=""
  rows=$(gh api "repos/$REPO/pulls/$1/files" --paginate \
           --jq '.[] | select(.filename | test("^stacks/.+/docker-compose\\.yml$")) | {f: .filename, p: (.patch // "")} | @json') || return 1
  while read -r row; do
    [ -n "$row" ] || continue
    f=$(jq -r .f <<<"$row")
    while read -r ref; do
      [ -n "$ref" ] || continue
      e=$(bash "$(dirname "${BASH_SOURCE[0]}")/image-age.sh" "$f" "$ref")
      if [ -z "$e" ]; then
        if [ -z "$fallback" ]; then
          fallback=$(gh api "repos/$REPO/commits/$2" --jq '.commit.committer.date') || return 1
          fallback=$(date -u -d "$fallback" +%s) || return 1
        fi
        e=$fallback
      fi
      if [ -z "$youngest" ] || [ "$e" -gt "$youngest" ]; then youngest=$e; fi
    done < <(jq -r .p <<<"$row" | sed -nE 's/^\+[[:space:]]*image:[[:space:]]*([^[:space:]#]+).*/\1/p')
  done <<<"$rows"
  echo "${youngest:-none}"
}
