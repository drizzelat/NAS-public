#!/usr/bin/env bash
# Commit an export.sh tree to the public mirror and push it: push.sh <export-dir>
# Needs MIRROR_REPO (owner/name) and MIRROR_DEPLOY_KEY (private half of the mirror's write deploy key).
set -euo pipefail

src=$(cd "${1:?usage: push.sh <export-dir>}" && pwd)
: "${MIRROR_REPO:?}" "${MIRROR_DEPLOY_KEY:?}"
label=$(git rev-parse --short HEAD)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(umask 077 && printf '%s\n' "$MIRROR_DEPLOY_KEY" >"$work/key")
curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' >"$work/known_hosts"
export GIT_SSH_COMMAND="ssh -i $work/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$work/known_hosts -o StrictHostKeyChecking=yes"

git clone -q --depth 1 "git@github.com:$MIRROR_REPO.git" "$work/mirror"
cd "$work/mirror"
git symbolic-ref HEAD refs/heads/main   # an empty mirror clones with no branch
rsync -a --delete --exclude /.git "$src/" ./
git add -A
if git diff --cached --quiet; then
  echo "mirror already matches $label"
  exit 0
fi
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -q -m "Sync from private main ($label)"
git push -q origin HEAD:main
echo "pushed $label to $MIRROR_REPO"
