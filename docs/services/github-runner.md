# Service: GitHub Actions Runner

## Overview

A self-hosted GitHub Actions runner for the `drizzelat/NAS` repo. It runs every workflow that
needs the LAN:

- [`deploy-stacks`](../../.github/workflows/deploy-stacks.yml) — on a push to `main`, send Komodo's
  `DeployStack` for each stack whose folder changed, so only that stack redeploys, creating a new one
  in Komodo first;
- the nightly [`nas-health-check`](../runbooks/setup-operations/nas-health-check.md) and the
  [`deploy-state-probe`](../runbooks/setup-operations/deploy-state-probe.md).

It runs in the [runner VM](../runbooks/setup-operations/runner-vm.md) on the NAS, on the LAN, so it can
reach Komodo Core (a LAN-only vhost) **without exposing Komodo to the internet**. It moved there from
a container on the NAS host on 2026-09-17 (SEC-1 step 4, SVC-2 Phase 3 PR 11).

## Stack

- **Stack folder:** `stacks/github-runner/`
- **Compose file:** `stacks/github-runner/docker-compose.yml`
- **Image:** `myoung34/github-runner` (ephemeral, re-registers per job)
- **Deploy:** Komodo Stack `github-runner` on Server `runner-vm`, deployed by the Komodo Procedure
  `deploy-runner`, never by CI. It is **not** in `komodo/owned-stacks`. See [Deploy path](#deploy-path).
- **Host:** the runner VM, `192.168.178.34`. Runner name `runner-vm`, label `nas`, which every
  self-hosted workflow's `runs-on` names.

## Env vars (vault → Komodo Variables, never committed)

| Var          | Purpose                                                          |
| ------------ | --------------------------------------------------------------- |
| `RUNNER_PAT` | GitHub PAT to fetch runner registration tokens. Classic: scope `repo`. Fine-grained: `Administration: Read and write` on `drizzelat/NAS`. |

## Ports

None. Outbound only (GitHub, Komodo over the LAN, the NAS host over SSH as `nashealth`).

## How it fits together

```
git push main ──► GitHub ──► workflow .github/workflows/deploy-stacks.yml
                              runs-on: [self-hosted, nas]
                              │  git diff -> changed stacks in komodo/owned-stacks
                              ▼
                  POST https://komodo.example.com/execute/DeployStack   (--resolve to the NAS)
                              ▼
                  Komodo Core -> the Stack's Server periphery: git pull + compose up
```

The Server comes from the Stack's entry in `komodo/resources.toml`, not the folder name. See the
[deploy-stacks runbook](../runbooks/setup-operations/deploy-stacks.md), which also covers new and
removed stacks.

## Deploy path

No job deploys the runner it runs on, so nothing kills its own job and no step is held back for
the end. Two pieces in [`komodo/resources.toml`](../../komodo/resources.toml):

- **The Procedure `deploy-runner`**, hourly at `:53` UTC, runs `DeployStackIfChanged` on this Stack. An
  unchanged compose recreates nothing.
- **The Stack's `pre_deploy`**, [`scripts/komodo/runner-idle.sh`](../../scripts/komodo/runner-idle.sh),
  waits until the container has no `Runner.Worker` process, checking every 10 s for up to an hour.
  After an hour the deploy fails, and the next hourly run tries again. Any deploy waits, including
  **Deploy** pressed in the UI.

A merged change to `stacks/github-runner/` therefore lands within the hour, between jobs.
`deploy-stacks` only logs a notice for it. A job can still start in the seconds between the idle
check and the recreate; that job dies with exit 143. Accepted (komodo-migration.md decision 13).

No health gate and no auto-rollback. The deploy-state probe sees the result.

While `pre_deploy` waits, Komodo shows the Stack as `deploying`. The job it waits for may be the
deploy-state probe or the health check, which both read that state, so both accept `deploying` for
this one Stack. Before they did, the probe run a waiting deploy measured failed on it (2026-09-17).

## Notes

- If the runner or its VM is down, pushes won't deploy until it's back. Komodo's hourly `reconcile-owned`
  Procedure still deploys a merged compose change, without the health gate, and **Deploy** on a Stack
  in Komodo works without the runner.
- `EPHEMERAL=true`: the runner registers fresh per job and deregisters after, so no
  stale offline runners pile up in GitHub.
- **Security:** this container executes workflow code in the runner VM, and its jobs are handed the
  Komodo deploy key and the `nashealth` SSH key. It's only safe
  because the repo is **private** and its jobs run only on push to `main`, `schedule` and
  `workflow_dispatch` (collaborators only — no fork/PR-triggered code), it mounts **no `docker.sock`**, and it runs
  with `no-new-privileges`. If the repo is ever made public or starts running
  `pull_request` workflows, this becomes RCE on the host — gate workflows first.

## Operations

> Restart/redeploy go through **Komodo** (Stack `github-runner`). Over SSH (`ssh -i secrets/ssh/runner-vm_ed25519 ubuntu@192.168.178.34`), `ubuntu` is not in the `docker` group but has passwordless sudo, so `sudo docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `github-runner` → **Deploy** (or **Restart**). Deploy waits for a running job
  first; Restart does not. `RUNNER_PAT` comes from the Komodo Variable `GITHUB_RUNNER__RUNNER_PAT`.
- **A new PAT:** `scripts/secrets.sh edit github-runner`, then `scripts/secrets.sh komodo-vars
  github-runner`, then **Deploy**. `secrets.sh push` refuses this stack, because it is not owned.
- **Sooner than `:53`:** Komodo → Procedures → `deploy-runner` → **Run**.

### Upgrade

- Pinned `myoung34/github-runner:<agent-version>-ubuntu-focal@sha256:…`. Renovate opens the PR, the review sweep merges it, and `deploy-runner` deploys it between jobs within the hour.
- **Do not go back to `latest`.** It carries no version string, so [renovate-pr-review](../runbooks/setup-operations/renovate-pr-review.md) has no release notes to read and judges a digest change blind ([SEC-5](../architecture-review-2026-08-20.md#sec-5--latest-tags-defeat-the-pr-review-gate)). Note `latest` is also its own build stream here — no versioned tag shares its digest, so the two are not interchangeable.
- **The base is Ubuntu 20.04 (focal), EOL since April 2025.** Moving to `-ubuntu-jammy` or `-ubuntu-noble` changes the toolchain every workflow runs against, so it is a deliberate separate change, not an image bump.
- **If a bump goes wrong the runner does not come back on its own**, and no workflow can run to fix it. Check over SSH on the VM (`sudo docker ps -a --filter name=github-runner`), revert the pin, then **Deploy** the Stack from Komodo, which does not need the runner.

### Restore from backup

- **Nothing to restore** — the runner is stateless and ephemeral (re-registers per job, deregisters after). Recovery = redeploy the stack with a valid `RUNNER_PAT`.

### Common failures

- **Pushes don't auto-deploy** → runner offline. Deploy the affected stack by hand in Komodo, or leave it to the hourly `reconcile-owned` Procedure, then fix the runner.
- **Runner won't register** → `RUNNER_PAT` expired or wrong scope (classic: `repo`; fine-grained: `Administration: Read and write` on `drizzelat/NAS`).
- Runner appears in GitHub → Settings → Actions → Runners **only while a job runs** (ephemeral) — absence there is normal when idle.
- **A job dies with `exit 143` / `The runner has received a shutdown signal`** → the Stack was
  recreated under it: **Restart** pressed in Komodo, or a job that started in the seconds after the
  idle check. Re-run the job.
- **`deploy-runner` fails with `still running a job after 3600s`** → a job ran for over an hour.
  The next hourly run tries again. A job that hangs keeps blocking it; cancel the job in GitHub.
- **The runner VM is down** → see [runner-vm.md → Common failures](../runbooks/setup-operations/runner-vm.md#common-failures).
- **A runner bump ships broken** → no later run starts at all, so CI cannot fix itself. Revert the
  `image:` pin with a merge by hand, then **Deploy** the Stack from Komodo, which does not need the
  runner.

## Last updated

2026-09-17 — moved into the runner VM (SEC-1 step 4): Stack on `runner-vm`, deployed between jobs by the `deploy-runner` Procedure; `DEFER_FIRE` and `fire-deferred.sh` deleted (SVC-2 Phase 3, PR 11).

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack on the deferred path (#386), env from Komodo Variables.

2026-09-11
