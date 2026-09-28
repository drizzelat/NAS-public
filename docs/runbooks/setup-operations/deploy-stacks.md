# Runbook: deploy-stacks — every stack through Komodo

A push to `main` that touches `stacks/**` runs [`deploy-stacks`](../../../.github/workflows/deploy-stacks.yml)
on the self-hosted runner. It deploys each changed stack through Komodo, health-checks it, and rolls a
stack back when it comes up unhealthy. A new stack is created in Komodo first. A removed stack is
**never** torn down by CI.

## What decides what gets deployed

- **The changed folders:** `git diff --no-renames before..after -- stacks/**` on a push, or the
  `stacks` input on a dispatch.
- **Ownership:** only names in [`komodo/owned-stacks`](../../../komodo/owned-stacks) are deployed. Any
  other changed folder gets a `::notice::` and nothing else:
  - **The peripheries**, applied by hand.
  - **`komodo`**, which deploys only when someone presses Deploy.
  - **`github-runner`**, which its own Procedure `deploy-runner` deploys between jobs
    ([github-runner.md](../../services/github-runner.md#deploy-path)).
- **The Server:** each Stack's `server` in [`komodo/resources.toml`](../../../komodo/resources.toml).
  The folder name no longer routes anything.

There is **no reconcile pass** in the workflow any more. The hourly Komodo Procedure `reconcile-owned`
is the backstop for a run GitHub evicted, and for a `DeployStack` dropped because the stack was busy
([komodo.md → A busy Stack drops a deploy](../../services/komodo.md#a-busy-stack-drops-a-deploy)). Its deploys get no
health gate; the [deploy-state probe](deploy-state-probe.md) sees their result.

## The steps

| Script | What it does |
| --- | --- |
| [`fire-webhooks.sh`](../../../scripts/deploy/fire-webhooks.sh) | Creates a new owned stack, then sends `DeployStack` for each changed one, waits for its update record, and checks the deployed commit |
| [`verify-healthy.sh`](../../../scripts/deploy/verify-healthy.sh) | Polls each deployed stack's services until they converge on the repo pins and are healthy, then auto-rolls back an unhealthy push-derived one |
| [`scripts/komodo/lib.sh`](../../../scripts/komodo/lib.sh) | The Komodo API calls both share |

The file name `fire-webhooks.sh` is historical. The scripts read only environment variables; the
`env:` block of each step in the workflow is their interface.

### Deploy

`komodo_deploy` waits for the Stack to go idle, because a busy Stack drops a request
([komodo.md → Rules](../../services/komodo.md#a-busy-stack-drops-a-deploy)). It then
sends `DeployStack` and follows the update record until it completes. A failed stage fails the step,
and the log shows the failed stages only; `Compose Config` is never printed whole, because it is the
interpolated file.

Then `komodo_check_commit` asserts that the commit Komodo deployed is the run's commit or a newer one.
A Komodo pull can be up to five seconds old, and a re-cloned repo strands directory mounts
([komodo.md → Rules](../../services/komodo.md#config-mounts-come-from-komodos-clone)). A config-mount stack's own `post_deploy` guards the second case too.

### A new stack

A folder whose name is in `komodo/owned-stacks` but has no Komodo Stack is created before it is
deployed, from `komodo/resources.toml`, through two syncs filtered to one resource each
([komodo.md → Rules](../../services/komodo.md#ci-creates-new-stacks-through-a-filtered-sync)):

1. **Check the entry.** Its `[[stack]]` entry must exist.
2. **Check the Variables.** Every Variable its `environment` names must already exist. CI holds no
   vault key, so a missing one fails the run with the command to run.
3. **Create the Stack:** `RunSync` filtered to `resource_type: Stack` and the one name.
4. **Refresh the backstop:** `RunSync` filtered to `resource_type: Procedure` and `reconcile-owned`,
   so the Procedure covers the new stack.
5. **Deploy it** as above, with the health gate.

If that deploy fails, the Procedure already names the stack, so it tries again at `:23`, unwatched. A
Stack that has never been deployed counts as changed.

Nothing else in the ResourceSync is applied by these runs. Any other pending change to
`resources.toml` still waits for someone to read the sync's diff and execute it by hand. The
[deploy-state probe](deploy-state-probe.md) fails when that has waited more than 6 h.

### Health and rollback

`verify-healthy.sh` reads a Stack's services through `read/ListStackServices`.

- **Convergence first:** every running service must be on a digest the repo pins. Health alone would
  pass on the previous deploy's containers.
- **Then health:** no container that is neither running nor a clean `Exited (0)`, and none running
  `unhealthy`.
- **Held for 60 s** (`STABLE_SECS`): one clean poll is not enough. Every poll also reads each
  container's `RestartCount` through `read/InspectStackContainer`, and a count that rose restarts the
  window. A crash loop that restarts between two 6-second polls reads `running` every time: the #547
  `crowdsec` loop passed this way on 2026-09-25 and ran for ~7 h until the
  [deploy-state probe](deploy-state-probe.md) caught it. A container that restarted and never held
  60 s clean before the ~4-minute budget ran out is a failure, and a rollback candidate.
- **A probe binary missing from the image** is not a failure. The last health log line comes from
  `read/InspectStackContainer`, piped straight into `jq`, because inspect output carries the
  container's environment.

Only a stack this **push** changed can be rolled back. The rollback is a commit restoring the
stack's folder from `before`, pushed to `main` as `ROLLBACK_TOKEN` with `[skip ci]`, then
`DeployStack` again. It can undo a bad pin or compose change. It **cannot** undo anything written
to a host path or a migrated database. At most two auto-rollbacks per stack per seven days, then the
run refuses and goes red.

A dispatched stack is never rolled back: there is no bad commit to revert, and reverting would undo
whatever commit happens to be newest.

## Adding a stack

One PR carrying:

- **The folder:** `stacks/<name>/docker-compose.yml`, plus the docs `docs-drift` requires.
- **The Komodo entry:** a `[[stack]]` entry in `komodo/resources.toml`, with `project_name = "<name>"`
  written out and `destroy_before_deploy = false`.
- **Ownership:** the name in `komodo/owned-stacks`, and in the `reconcile-owned` pattern in
  `resources.toml`. `check-owned.sh` enforces both.

If the stack has env, run `scripts/secrets.sh edit <name>` and `scripts/secrets.sh komodo-vars <name>`
from the workstation **before** merging. Merging then creates and deploys it; no `[skip ci]` and no
hand sync are needed.

Full checklist: [new-service.md](new-service.md).

## `[skip ci]` does not stop a deploy

**Komodo deploys the estate on its own schedule, whatever GitHub does.** The `reconcile-owned`
Procedure in [`komodo/resources.toml`](../../../komodo/resources.toml) runs **hourly at :23 UTC** and
runs `DeployStackIfChanged` over every name in [`komodo/owned-stacks`](../../../komodo/owned-stacks),
and `deploy-runner` does the same for `github-runner` at :53. A merge whose commit message carries
`[skip ci]` suppresses the `deploy-stacks` workflow and nothing else: the next `:23` deploys every
stack whose compose changed, all at once.

This bit on 2026-09-23. A change touching 25 stacks was merged at 15:19 with `[skip ci]`, intending a
hand-paced batch deploy; `reconcile-owned` fired at 15:23 and recreated the whole estate. Nothing was
lost — but `files` crash-looped for two minutes (`[FATAL] Error validating OIDC auth … 503 Service
Unavailable: authentik starting`) because it validates OIDC at startup and Authentik was restarting
in the same pass, and the deploy-state probe caught `romm` mid-healthcheck.

**To actually pace a wide change**, disable the Procedure's schedule first
(`schedule_enabled = false` in `resources.toml`, or the toggle in Komodo's UI), merge, deploy the
batches by hand, then re-enable it. A merge inside the ~50 minutes before `:23` is not a plan.

## Removing a stack

CI never removes anything. Komodo's `DestroyStack` is a `compose down`, and on `caddy` that would take
networks other stacks depend on
([komodo.md → Rules](../../services/komodo.md#destroystack-is-compose-down)). So:

1. **The PR:** delete the folder, its `[[stack]]` entry and its `owned-stacks` line, and remove it
   from the Procedure pattern.
   - Merging logs a `::warning::` and tears nothing down.
   - The deploy-state probe goes red: the Komodo Stack now has no folder, and its containers belong
     to no repo compose.
   - Until step 2, `reconcile-owned` still names the stack and skips it without an error.
2. **Update the backstop:** read the sync diff and execute it, or run `RunSync` filtered to
   `Procedure` / `reconcile-owned`, so the hourly Procedure stops naming the stack.
3. **Take it down by hand:** Komodo → the Stack → **Destroy**, after checking that it defines no
   network another stack uses. Destroy runs `docker compose -p <name> down`, so it works with the
   folder already gone from the clone.
4. **Delete the Stack:** clear its Server first, then delete. Deleting a Stack that still has a Server
   runs `compose down` too.
5. **Check:** dispatch the probe. It is green again.

## Running it by hand

- **Deploy named stacks:** `gh workflow run deploy-stacks.yml -f stacks="homarr paperless"`.
- **Rehearse without deploying:** add `-f komodo_dry_run=true`. Every Komodo read still happens, and
  the log says which create and `DeployStack` each stack would get.
- **One stack out of a commit that touched two:** merge with `[skip ci]`, then dispatch that one
  stack. Keep clear of `:23`, when `reconcile-owned` would deploy the merged change unwatched.

## Gotchas

- **A stack changed by two queued runs.** `verify-healthy.sh` re-reads each stack's compose from
  `origin/main` and skips a stack whose intended state has moved on, with a `::warning::`. The newer
  run owns it.
- **Runs cancelled in a merge burst.** The `deploy-stacks` concurrency group keeps one pending run,
  and GitHub cancels the older one before it has any job. The merge sweep in `renovate-pr-review.yml`
  waits for each deploy, and `reconcile-owned` picks up what still slips through within the hour.
- **Renaming a stack is a removal plus an addition.** CI never tears the old one down, so the new
  one would collide with it on `container_name` or host ports. Merge the rename with `[skip ci]`,
  destroy and delete the old Stack by hand, then dispatch the new name. Rename its
  `secrets.enc/stack-env/<name>.env.age` and run `komodo-vars` for the new name first.
- **Runner down means no deploy.** Press Deploy on the Stack in Komodo; that does not need the runner.
- **A healthcheck that fails because its probe tool is not in the image.** The container reads
  `unhealthy` while the app works in a browser: an HTTP healthcheck needs `curl` or `wget` inside the
  image, and a base-image bump can remove it. `compose-validate` cannot see this. Confirm with
  `sudo -n docker inspect <name> | jq '.[0].State.Health.Log[-1].Output'`: `wget: not found` or
  `curl: not found` is the tell. Fix by dropping the healthcheck or layering a static busybox in.
  Audit these when their base image changes:

  | Stack | Probe needs |
  | --- | --- |
  | `paperless` (webserver) | curl |
  | `files` | curl |
  | `homarr` | wget |
  | `romm` | wget (busybox) |
  | `mealie` | python3 |

  `gluetun` unhealthy is **not** this class: its probe is bundled, so it is a real tunnel or DNS
  failure ([downloads.md](../../services/downloads.md)).

