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
reach Komodo Core (a LAN-only vhost) **without exposing Komodo to the internet**, and so workflow code never runs on the NAS host
itself.

## Stack

- **Stack folder:** `stacks/github-runner/`
- **Compose file:** `stacks/github-runner/docker-compose.yml`
- **Image:** `myoung34/github-runner` (ephemeral, re-registers per job)
- **Deploy:** Komodo Stack `github-runner` on Server `runner-vm`, deployed by the Komodo Procedure
  `deploy-runner`, never by CI. It is **not** in `komodo/owned-stacks`. See [Deploy path](#deploy-path).
- **Host:** the runner VM, `192.168.1.34`. Runner name `runner-vm`, label `nas`, which every
  self-hosted workflow's `runs-on` names.

## Env vars (vault → Komodo Variables, never committed)

| Var          | Purpose                                                          |
| ------------ | --------------------------------------------------------------- |
| `APP_ID` | ID of the GitHub App `drizzelat-nas-runner`, which mints the registration tokens. Installed on `drizzelat/NAS` only; permissions **Administration: write** and metadata read, nothing else |
| `APP_PRIVATE_KEY` | That App's private key as **one line**, newlines written as a literal `\n` (Komodo's `environment` block is line-based). The entrypoint restores them. The only copy is in the vault |

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
check and the recreate; that job dies with exit 143. Accepted
([komodo.md → Rules](komodo.md#github-runner-deploys-between-jobs)).

No health gate and no auto-rollback. The deploy-state probe sees the result.

While `pre_deploy` waits, Komodo shows the Stack as `deploying`. The job it waits for may be the
deploy-state probe or the health check, which both read that state, so both accept `deploying` for
this one Stack.

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
- **Jobs run as `runner`, not root, and the registration credential is out of their reach** (SEC-1).
  `RUN_AS_ROOT=false` runs the Listener through `gosu` as `runner`, and `UNSET_CONFIG_VARS=true` drops the
  credential from the entrypoint's environment before the Listener starts. `no-new-privileges` keeps the
  image's passwordless `sudo` from escalating: **a step that needs `sudo` fails** (`sudo: The "no new
  privileges" flag is set, which prevents sudo from running as root.`). No self-hosted job needs root: they
  check out, `curl`, `ssh` with a key from `$RUNNER_TEMP`, and install `claude` into `~/.local`. A job that
  needs a system package belongs on a GitHub-hosted runner.

**Container logs** are capped at 10 MB × 3 files per container (`x-logging` in the compose file):
Docker's `json-file` default never rotates. Enforced by
[`compose-policy.py`](../../.github/scripts/compose-policy.py).

## Operations

> Restart/redeploy go through **Komodo** (Stack `github-runner`). Over SSH (`ssh -i secrets/ssh/runner-vm_ed25519 ubuntu@192.168.1.34`), `ubuntu` is not in the `docker` group but has passwordless sudo, so `sudo docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `github-runner` → **Deploy** (or **Restart**). Deploy waits for a running job
  first; Restart does not. `APP_ID` and `APP_PRIVATE_KEY` come from the Komodo Variables `GITHUB_RUNNER__APP_ID` and `GITHUB_RUNNER__APP_PRIVATE_KEY`.
- **A new PAT:** `scripts/secrets.sh edit github-runner`, then `scripts/secrets.sh komodo-vars
  github-runner`, then **Deploy**. `secrets.sh push` refuses this stack, because it is not owned.
- **Sooner than `:53`:** Komodo → Procedures → `deploy-runner` → **Run**.

### Upgrade

- Pinned `myoung34/github-runner:<agent-version>-ubuntu-noble@sha256:…`. Renovate opens the PR, the review sweep merges it, and `deploy-runner` deploys it between jobs within the hour.
- **Do not go back to `latest`.** It carries no version string, so [renovate-pr-review](../runbooks/setup-operations/renovate-pr-review.md) has no release notes to read and judges a digest change blind. Note `latest` is also its own build stream here — no versioned tag shares its digest, so the two are not interchangeable.
- **The base is Ubuntu 24.04 (noble)** since 2026-09-23. It was focal (EOL April 2025), which carried 271 HIGH / 11 CRITICAL fixable CVEs in the image scan. Upstream installs the same packages on every variant, and the self-hosted jobs use only `jq`, `curl`, `git`, `ssh` (an ed25519 key, fine on OpenSSH 9.6) and coreutils. Changing the distro suffix is still a deliberate edit: Renovate keeps a pin on its suffix.
- **If a bump goes wrong the runner does not come back on its own**, and no workflow can run to fix it. Check over SSH on the VM (`sudo docker ps -a --filter name=github-runner`), revert the pin, then **Deploy** the Stack from Komodo, which does not need the runner.

### Restore from backup

- **Nothing to restore** — the runner is stateless and ephemeral (re-registers per job, deregisters after). Recovery = redeploy the stack with valid App credentials.

### Common failures

- **Pushes don't auto-deploy** → runner offline. Deploy the affected stack by hand in Komodo, or leave it to the hourly `reconcile-owned` Procedure, then fix the runner.
- **A self-hosted step fails with `sudo: The "no new privileges" flag is set…` or `Permission denied` under `/usr`** → jobs run as `runner` without root (see Notes). Move the step to a GitHub-hosted job, or install into `$HOME`.
- **Runner won't register** → the container log shows the step: `Obtaining access token for app_id` failing means a wrong key, a key with real newlines lost in the one-line form, or the App uninstalled from the repo. Check the App under Settings → Developer settings → GitHub Apps → `drizzelat-nas-runner` (Administration: write, installed on `drizzelat/NAS`). **Rotating the key:** generate a new one there, replace `APP_PRIVATE_KEY` with `secrets.sh edit github-runner` (one line, `\n` for each newline), run `komodo-vars github-runner`, then `deploy-runner`, and delete the old key in the App settings.
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
