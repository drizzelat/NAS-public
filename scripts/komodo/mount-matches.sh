#!/bin/sh
# post_deploy guard: fail unless <container> sees exactly the clone's files at <dir> (komodo-migration.md F28).
# Run from the Stack's run directory: sh ../../scripts/komodo/mount-matches.sh <container> <dir> <clone-dir>
set -eu
[ $# -eq 3 ] || { echo "usage: mount-matches.sh <container> <container-dir> <clone-dir>" >&2; exit 2; }

# Komodo writes a root-only .env into the run directory, which a whole-folder mount also shows.
list='find . -type f ! -name .env -exec sha256sum {} + | LC_ALL=C sort -k2'
inside=$(docker exec "$1" sh -c "cd '$2' && $list")
outside=$(cd "$3" && sh -c "$list")
if [ "$inside" != "$outside" ]; then
  echo "$1: $2 differs from the clone's $3, so the mount is stale. Recreate the container." >&2
  exit 1
fi
echo "$1: $2 matches the clone ($(printf '%s\n' "$outside" | grep -c .) files)"
