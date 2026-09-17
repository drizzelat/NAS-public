#!/usr/bin/env bash
# Poll Komodo until every touched stack's containers are running/healthy, then
# auto-roll-back the ones that are not. Docs: docs/runbooks/setup-operations/deploy-stacks.md

set -uo pipefail
# shellcheck source=scripts/komodo/lib.sh
. "$(dirname "$0")/../komodo/lib.sh"
# Phase 1 waits for CONVERGENCE (containers run this repo's pins), phase 2 judges
# health — health alone passes on the PREVIOUS deploy's containers.
TRIES=40; GAP=6        # ~4 min of health polling
CONVERGE_STALL=240    # 4 min of nothing changing -> stop waiting
CONVERGE_MAX=2700     # 45 min absolute ceiling, backstop only

# Intentionally a no-op: the alert channel is GitHub's workflow-failure email.
# Wire in ntfy/Telegram here if that ever stops being enough.
alert() {  # alert <stack> <detail>
  return 0
}

# The Stack's services that have a container, in the Docker API's list shape so the checks
# below read it unchanged. Komodo refreshes this from the host every few seconds.
containers() {  # containers <stack>  -> JSON array of {Names, State, Status, Image, Service}
  kapi read/ListStackServices "$(jq -nc --arg s "$1" '{stack:$s}')" \
    | jq -c '[.[] | select(.container) | {Names: ["/" + .container.name], State: .container.state,
              Status: (.container.status // ""), Image: (.container.image // ""), Service: .service}]'
}

# Last healthcheck log line; tells a genuine failure from a missing probe binary. Never print the
# inspect output whole: it carries the container's environment.
health_log() {  # health_log <stack> <service>
  kapi read/InspectStackContainer "$(jq -nc --arg s "$1" --arg v "$2" '{stack:$s,service:$v}')" 2>/dev/null \
    | jq -r '(.State.Health.Log // []) | (last // {}) | (.Output // "")' 2>/dev/null \
    || echo ""
}

# Running containers whose digest this repo does not pin. RUNNING only — an
# exited one-shot keeps its old digest and would block convergence forever.
stale_containers() {  # stale_containers <containers-json> <pins>  -> names
  local json="$1" pins="$2" row name ref d out=""
  for row in $(printf '%s' "$json" | jq -r '.[] | select(.State=="running") | "\(.Names[0])|\(.Image)"'); do
    name=${row%%|*}; ref=${row#*|}
    d=$(printf '%s' "$ref" | grep -oE 'sha256:[0-9a-f]{64}') || continue
    printf '%s\n' "$pins" | grep -qx "$d" || out="$out ${name#/}"
  done
  printf '%s' "$(echo $out | xargs)"
}

# Progress fingerprint: the container->image set and states. Komodo's deploy has already pulled,
# so any change here is the recreate still moving; it resets the stall clock.
converge_state() {  # converge_state <stack> -> fingerprint
  local json
  json=$(containers "$1" 2>/dev/null || echo '[]')
  printf '%s' "$json" | jq -r '[.[] | "\(.Names[0]):\(.Image):\(.State)"] | sort | join(",")' 2>/dev/null
}

# Phase 1. Returns 0 converged, 2 gave up — NEVER 1: "did not land" is an
# unknown, not evidence the pin is bad, so it must not trigger a rollback.
wait_converged() {  # wait_converged <stack>
  local stack="$1" json="" pins="" stale="" count="" prev_count="-1" min=0
  local fp="" prev_fp="" stall=0 elapsed=0
  LAST_DETAIL=""
  pins=$(grep -oE 'sha256:[0-9a-f]{64}' "stacks/$stack/docker-compose.yml" 2>/dev/null | sort -u)
  # Nothing digest-pinned -> nothing to converge on.
  [ -n "$pins" ] || return 0
  # One line per pinned service (not the deduped pin list — services may share an image).
  min=$(grep -cE '^[[:space:]]*image:[^#]*sha256:' "stacks/$stack/docker-compose.yml")
  while : ; do
    json=$(containers "$stack") || json=""
    if [ -n "$json" ]; then
      count=$(printf '%s' "$json" | jq 'length')
      if [ "$count" = "0" ]; then
        # Mid-recreate window: restart the stability count so an empty poll is never
        # mistaken for a settled stack.
        prev_count="-1"
      else
        stale=$(stale_containers "$json" "$pins")
        if [ -z "$stale" ] && [ "$count" = "$prev_count" ] && [ "$count" -ge "$min" ]; then
          echo "converged: $stack runs the repo pins ($count containers)"
          return 0
        fi
        prev_count="$count"
      fi
    fi
    # Stall clock. Reset on any observable movement, tick otherwise.
    fp=$(converge_state "$stack")
    if [ "$fp" != "$prev_fp" ]; then
      stall=0; prev_fp="$fp"
    else
      stall=$((stall + GAP))
    fi
    # One line per minute, not one per poll.
    if [ "$((elapsed % 60))" = "0" ]; then
      if [ -n "$stale" ]; then
        echo "waiting for redeploy of $stack — still on old images: $stale (${elapsed}s)"
      elif [ -n "$count" ] && [ "$count" -lt "$min" ]; then
        echo "waiting for redeploy of $stack — $count/$min containers back up (${elapsed}s)"
      fi
    fi
    if [ "$stall" -ge "$CONVERGE_STALL" ]; then
      LAST_DETAIL="  deploy stopped making progress: nothing changed for ${CONVERGE_STALL}s (${elapsed}s elapsed)"
      break
    fi
    if [ "$elapsed" -ge "$CONVERGE_MAX" ]; then
      LAST_DETAIL="  deploy still had not converged after ${CONVERGE_MAX}s"
      break
    fi
    sleep "$GAP"; elapsed=$((elapsed + GAP))
  done
  # Say WHICH way it failed to converge, but classify both as "did not land".
  # The next run's reconcile pass retries it for free.
  if [ -n "$stale" ]; then
    LAST_DETAIL="$(printf '%s\n  still running images this repo does not pin: %s' "$LAST_DETAIL" "$stale")"
  elif [ -n "$count" ] && [ "$count" -lt "$min" ]; then
    LAST_DETAIL="$(printf '%s\n  only %s of %s pinned services have containers' "$LAST_DETAIL" "$count" "$min")"
  fi
  return 2
}

# Poll one stack until healthy. 0 healthy, 1 UNHEALTHY (only code that may roll
# back), 2 NOT CONVERGED. Prints live — do not wrap in $(...).
check_stack() {  # check_stack <stack>
  local stack="$1" json="" hard_bad="" unhealthy_run="" starting=""
  LAST_DETAIL=""
  # Propagate wait_converged's code verbatim — collapsing 2 into 1 is what let a
  # slow pull revert a good commit.
  wait_converged "$stack" || return $?
  for _ in $(seq 1 "$TRIES"); do
    json=$(containers "$stack") || { sleep "$GAP"; continue; }
    if [ "$(printf '%s' "$json" | jq 'length')" = "0" ]; then
      # No containers yet (redeploy still pulling/recreating) — wait.
      sleep "$GAP"; continue
    fi
    # hard_bad: not running and not a clean `Exited (0)` — tolerates run-once/init
    # containers, still catches crash-loops and nonzero exits.
    hard_bad=$(printf '%s' "$json" \
      | jq -r '.[] | select(.State != "running" and ((.Status|test("Exited \\(0\\)"))|not)) | .Names[0]')
    # unhealthy_run: running but healthcheck failing — rollback candidate.
    unhealthy_run=$(printf '%s' "$json" \
      | jq -r '.[] | select(.State == "running" and (.Status|test("unhealthy"))) | .Names[0]')
    # starting: healthcheck still in start_period — keep waiting.
    starting=$(printf '%s' "$json" \
      | jq -r '.[] | select(.Status|test("health: starting")) | .Names[0]')
    if [ -z "$hard_bad" ] && [ -z "$unhealthy_run" ] && [ -z "$starting" ]; then
      return 0
    fi
    sleep "$GAP"
  done

  # Budget exhausted. A missing probe binary (curl/wget not in the image) is a
  # false alarm, not a failure.
  local genuine="$hard_bad" c log svc
  for c in $unhealthy_run; do
    svc=$(printf '%s' "$json" | jq -r --arg n "$c" '.[] | select(.Names[0] == $n) | .Service')
    log=$(health_log "$stack" "$svc")
    if printf '%s' "$log" | grep -qiE 'not found|no such file|executable file not found|not installed'; then
      echo "::warning::${c#/}: healthcheck probe missing from image (\"$(printf '%s' "$log" | tr -d '\r\n' | head -c 100)\") — app likely up; NOT treating as failure"
    else
      genuine="$genuine $c"
    fi
  done
  genuine=$(echo $genuine | xargs)
  if [ -z "$genuine" ]; then
    echo "OK (probe-missing only): $stack has no genuine failure"
    return 0
  fi
  LAST_DETAIL=$(printf '%s' "$json" | jq -r '.[] | "  \(.Names[0]): \(.State) / \(.Status)"' 2>/dev/null \
    || echo "  (no container data)")
  return 1
}

# Skip stacks whose compose has moved on from this run's checkout — a newer run
# owns them, and chasing an already-reverted pin burns the whole budget.
LIVE_MAIN=""
if git fetch --quiet origin main 2>/dev/null; then
  LIVE_MAIN=$(git rev-parse FETCH_HEAD 2>/dev/null || echo "")
fi
[ -n "$LIVE_MAIN" ] || echo "::warning::could not read origin/main — verifying against this run's checkout"
moved_on() {  # moved_on <stack>  -> 0 when live main differs from checkout
  [ -n "$LIVE_MAIN" ] || return 1
  local f="stacks/$1/docker-compose.yml" here there
  here=$(git show "HEAD:$f" 2>/dev/null | sha1sum | cut -d' ' -f1)
  there=$(git show "$LIVE_MAIN:$f" 2>/dev/null | sha1sum | cut -d' ' -f1)
  # Absent on main (deleted, or never there) -> nothing to compare against.
  [ -n "$there" ] && [ "$there" != "$(printf '' | sha1sum | cut -d' ' -f1)" ] || return 1
  [ "$here" != "$there" ]
}

echo "Waiting 15s for redeploys to start..."; sleep 15
overall=0; unhealthy=""; stalled=""; skipped=""; rc=0
for stack in $STACKS; do
  echo "::group::health $stack"
  if moved_on "$stack"; then
    echo "::warning::$stack: main has moved on since this run checked out — skipping verification, a newer run owns this stack"
    skipped="$skipped $stack"
    echo "::endgroup::"
    continue
  fi
  check_stack "$stack"; rc=$?
  case "$rc" in
    0)
      echo "OK: $stack healthy" ;;
    2)
      # NOT a rollback candidate. See the rollback block below.
      echo "::error::$stack did not finish deploying:"
      printf '%s\n' "$LAST_DETAIL"
      alert "$stack" "$LAST_DETAIL"
      stalled="$stalled $stack"; overall=1 ;;
    *)
      echo "::error::$stack not healthy after redeploy:"
      printf '%s\n' "$LAST_DETAIL"
      alert "$stack" "$LAST_DETAIL"
      unhealthy="$unhealthy $stack"; overall=1 ;;   # names only, for rollback
  esac
  echo "::endgroup::"
done
skipped=$(echo $skipped | xargs)
[ -z "$skipped" ] || echo "skipped (main moved on): $skipped"

[ "$overall" = 0 ] && exit 0

# Did not converge = UNKNOWN, so HANDS OFF main. Go red and let the next run's
# reconcile pass retry it.
stalled=$(echo $stalled | xargs)
if [ -n "$stalled" ]; then
  echo "::error::deploy never converged for: $stalled — NOT rolling back (nothing proves the new pin is bad). The next run's reconcile pass will retry it; check the stack's last update record in Komodo."
  alert "$stalled" "deploy did not converge; main left untouched"
fi

# Auto-rollback: restore ONLY the unhealthy stack's compose to pre-push, push,
# re-fire its webhook. Run still exits non-zero.
unhealthy=$(echo $unhealthy | xargs)
# Nothing broken, only stacks that failed to land -> stop here, main clean.
[ -n "$unhealthy" ] || exit 1
echo "::warning::auto-rollback for unhealthy stack(s): $unhealthy"
git config user.name "nas-deploy-bot"
git config user.email "deploy@nas.invalid"
# Base on the CURRENT tip of main: another automerge may have landed, and
# committing on the old checkout SHA would be a non-fast-forward.
git fetch origin main || { echo "::error::git fetch failed — cannot base rollback on live main"; exit 1; }
git checkout -B _rollback origin/main
restored=""
for stack in $unhealthy; do
  # Reconciled/dispatched stacks are not rollback candidates: the repo pin is the
  # intended state, so there is no bad commit to revert.
  case " $ROLLBACKABLE " in
    *" $stack "*) ;;
    *) echo "::error::'$stack' was redeployed by the reconcile/dispatch path and came up unhealthy — NOT rolling back main (the repo pin is intended state). Fix prod, or revert the pin by hand."
       continue;;
  esac
  # Loop breaker: two auto-rescues max, else main flaps revert/re-bump nightly
  # with nobody watching.
  rb_count=$(git log --since='7 days ago' --format=%s origin/main -- "stacks/$stack/" 2>/dev/null \
             | sed -n 's/^revert(deploy): roll back unhealthy stack(s): \(.*\) \[skip ci\]$/\1/p' \
             | tr ' ' '\n' | grep -cxF "$stack") || rb_count=0
  if [ "${rb_count:-0}" -ge 2 ]; then
    echo "::error::'$stack' has already been auto-rolled-back $rb_count times in the last 7 days and is failing again — refusing to flap main. Hold the pin in Renovate (or fix the stack) by hand."
    alert "$stack" "repeated rollback suppressed after $rb_count attempts — needs a human"
    continue
  fi
  if git checkout "$BEFORE" -- "stacks/$stack/" 2>/dev/null; then
    restored="$restored $stack"
  else
    echo "::warning::no pre-push state for '$stack' at $BEFORE — cannot roll back"
  fi
done
restored=$(echo $restored | xargs)
if [ -z "$restored" ]; then
  echo "::error::nothing could be rolled back"; exit 1
fi
# [skip ci] is LOAD-BEARING: the push goes out as a PAT, and PAT pushes
# re-trigger workflows.
if ! git commit -m "revert(deploy): roll back unhealthy stack(s): $restored [skip ci]"; then
  echo "::error::rollback produced no diff (stack was already at pre-push state?)"; exit 1
fi
# Do NOT re-fire on a rejected push: main still holds the bad bump.
if ! git push origin HEAD:main; then
  echo "::error::rollback push to main REJECTED — prod still on the bad bump; fix by hand"
  alert "$restored" "ROLLBACK PUSH FAILED — main still broken, manual revert needed"
  exit 1
fi
for stack in $restored; do
  echo "re-deploy (rolled-back) $stack through Komodo"
  komodo_deploy "$stack" || echo "::error::rollback Komodo deploy failed for $stack — prod NOT restored automatically"
done
alert "$restored" "auto-rolled back to pre-push state; verify prod + read release notes"
echo "::error::rolled back unhealthy stack(s): $restored — run failed for visibility"
exit 1
