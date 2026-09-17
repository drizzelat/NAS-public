#!/usr/bin/env bash
# Deploy every changed stack in komodo/owned-stacks through Komodo, creating a new one first.
# Driven entirely by env from deploy-stacks.yml. Docs: docs/runbooks/setup-operations/deploy-stacks.md

set -euo pipefail
# shellcheck source=scripts/komodo/lib.sh
. "$(dirname "$0")/../komodo/lib.sh"
OWNED=$(komodo_owned | xargs)

# What to deploy: the folders this push changed, or the dispatched names.
pushed=""
if [ "$EVENT" = "push" ]; then
  # Brand-new branch: BEFORE is all-zeros, not a real commit.
  if [ -z "$BEFORE" ] || [ "$BEFORE" = "0000000000000000000000000000000000000000" ]; then
    BEFORE="$AFTER^"
  fi
  # --no-renames: a folder rename must surface as a removal plus an addition.
  pushed=$(git diff --no-renames --name-only "$BEFORE" "$AFTER" -- 'stacks/**' \
    | cut -d/ -f2 | sort -u)
else
  # Dispatch: no pre-push state. Blank BEFORE so rollback cannot revert a commit
  # this run never deployed.
  BEFORE=""
  pushed=$(printf '%s' "${DISPATCH_STACKS:-}" | tr ' ,' '\n\n' | sed '/^$/d' | sort -u)
fi
# Pre-push ref for the rollback step.
echo "before=$BEFORE" >> "$GITHUB_OUTPUT"
# ONLY push-derived stacks may be rolled back — for dispatched ones the repo is right.
echo "rollbackable=$(echo $pushed | xargs)" >> "$GITHUB_OUTPUT"
if [ -z "$pushed" ]; then
  # A lost run is picked up by the reconcile-owned Procedure, not here (komodo-migration.md F16).
  echo "Nothing to deploy: no stack folder changed."
  echo "changed=" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "Requested stacks (from $EVENT):"; echo "$pushed"

fail=0
touched=""   # stacks deployed here, for the health check

for stack in $pushed; do
  if [ ! -d "stacks/$stack" ] && [ "$EVENT" != "push" ]; then
    echo "::error::there is no stacks/$stack folder to deploy"; fail=1; continue
  fi
  if [ ! -d "stacks/$stack" ]; then
    # Never torn down from CI: Komodo's DestroyStack is a compose down (komodo-migration.md §10).
    case " $OWNED " in *" $stack "*)
      echo "::error::'$stack' is still in komodo/owned-stacks but its folder is gone. Remove it from owned-stacks and resources.toml in the same PR"
      fail=1;;
    esac
    if komodo_stack_exists "$stack"; then
      echo "::warning::stacks/$stack was removed. CI tears nothing down; remove its Komodo Stack by hand (docs/runbooks/setup-operations/deploy-stacks.md#removing-a-stack). The deploy-state probe fails until then"
    else
      echo "::notice::stacks/$stack was removed; it has no Komodo Stack, so there is nothing to tear down in Komodo"
    fi
    continue
  fi
  case " $OWNED " in *" $stack "*) ;; *)
    echo "::notice::'$stack' is not in komodo/owned-stacks, so CI does not deploy it (see docs/services/$stack.md)"
    continue;;
  esac

  if ! komodo_stack_exists "$stack"; then
    echo "create $stack in Komodo from komodo/resources.toml"
    komodo_create "$stack" || { fail=1; continue; }
  fi

  # Synchronous: returns when compose up and post_deploy have finished. auto_pull does the pull.
  echo "deploy $stack through Komodo"
  rc=0; komodo_deploy "$stack" || rc=$?
  # Any failure fails this step, which skips verify-healthy and its rollback.
  if [ "$rc" != 0 ]; then
    fail=1; continue
  fi
  [ "${KOMODO_DRY_RUN:-false}" = true ] && continue
  komodo_check_commit "$stack" "$AFTER" || { fail=1; continue; }
  touched="$touched $stack"
done
# Stack names deployed here, for the health check.
echo "changed=$(echo $touched | xargs)" >> "$GITHUB_OUTPUT"
exit $fail
