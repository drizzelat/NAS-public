#!/bin/sh
# pre_deploy guard for github-runner: wait until no job is running, so the recreate lands between jobs
# (komodo-migration.md F27). Run from the Stack's run directory:
#   sh ../../scripts/komodo/runner-idle.sh <container> <max-seconds>
set -eu
[ $# -eq 2 ] || { echo "usage: runner-idle.sh <container> <max-seconds>" >&2; exit 2; }
waited=0
while :; do
  # Absent or stopped (a first deploy, or between an ephemeral runner's exit and its restart).
  if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" != true ]; then
    echo "$1 is not running, so there is no job to wait for"; exit 0
  fi
  # Fail closed: an error here must never read as idle. docker top needs a pid column.
  procs=$(docker top "$1" -eo pid,args) || { echo "docker top $1 failed, not deploying" >&2; exit 1; }
  case "$procs" in
    *Runner.Worker*) ;;
    *) echo "$1 is idle (no Runner.Worker) after ${waited}s"; exit 0 ;;
  esac
  if [ "$waited" -ge "$2" ]; then
    echo "$1 is still running a job after ${2}s, not deploying. The next deploy-runner run tries again." >&2
    exit 1
  fi
  sleep 10; waited=$((waited + 10))
done
