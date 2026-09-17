#!/usr/bin/env bash
# Stage an export.sh tree on a clone of the public mirror, then publish exactly what was reviewed.
#   mirror.sh stage <export-dir> <work-dir>     writes full.diff + files.txt there; outputs changed, diff_sha
#   mirror.sh publish <export-dir> <diff-sha>   stages again and pushes only if the diff still hashes to <diff-sha>
# Needs MIRROR_REPO and MIRROR_DEPLOY_KEY; GH_TOKEN is optional. docs/runbooks/setup-operations/public-mirror.md
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
emit() { echo "$1"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1" >>"$GITHUB_OUTPUT"; }

: "${MIRROR_REPO:?}" "${MIRROR_DEPLOY_KEY:?}"
priv=$(mktemp -d)
trap 'rm -rf "$priv"' EXIT
(umask 077 && printf '%s\n' "$MIRROR_DEPLOY_KEY" >"$priv/key")
# Authenticated when GH_TOKEN is set: the anonymous API limit is shared across runner IPs.
curl -fsS ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} https://api.github.com/meta \
  | jq -r '.ssh_keys[] | "github.com " + .' >"$priv/known_hosts"
export GIT_SSH_COMMAND="ssh -i $priv/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$priv/known_hosts -o StrictHostKeyChecking=yes"

stage() {   # <export-dir> <work-dir>
  local src
  src=$(cd "$1" && pwd)
  mkdir -p "$2"
  git clone -q --depth 1 "git@github.com:$MIRROR_REPO.git" "$2/mirror"
  git -C "$2/mirror" symbolic-ref HEAD refs/heads/main   # an empty mirror clones with no branch
  rsync -a --delete --exclude /.git "$src/" "$2/mirror/"
  git -C "$2/mirror" add -A
  git -C "$2/mirror" diff --cached --binary >"$2/full.diff"
  git -C "$2/mirror" diff --cached --name-status >"$2/files.txt"
}

case ${1:-} in
  stage)
    stage "${2:?export-dir}" "${3:?work-dir}"
    if [ -s "$3/full.diff" ]; then emit changed=true; else emit changed=false; fi
    emit "diff_sha=$(sha256sum <"$3/full.diff" | cut -d' ' -f1)"
    ;;
  publish)
    want=${3:?diff-sha}
    stage "${2:?export-dir}" "$priv/work"
    got=$(sha256sum <"$priv/work/full.diff" | cut -d' ' -f1)
    [ "$got" = "$want" ] || die "the mirror diff is not the one that was reviewed (now $got, reviewed $want)"
    [ -s "$priv/work/full.diff" ] || { echo "mirror already current"; exit 0; }
    label=$(git rev-parse --short HEAD)
    git -C "$priv/work/mirror" -c user.name='github-actions[bot]' \
      -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
      commit -q -m "Sync from private main ($label)"
    git -C "$priv/work/mirror" push -q origin HEAD:main
    echo "published $label to $MIRROR_REPO"
    ;;
  *) die "usage: mirror.sh stage <export-dir> <work-dir> | publish <export-dir> <diff-sha>" ;;
esac
