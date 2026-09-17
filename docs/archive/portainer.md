# Service: Portainer

> **Archived 2026-09-17.** Portainer EE was removed in SVC-2 Phase 3 of the
> [Komodo migration](../runbooks/setup-operations/komodo-migration.md): the TrueNAS app was stopped
> and deleted, and its stack rows went with its database, so nothing ever ran `compose down` through
> it. Nothing here describes anything running. Every stack deploys through
> [Komodo](../services/komodo.md). The data is still on disk at `/mnt/apps/portainer`, plus the ZFS
> snapshot `apps/portainer@pre-removal-2026-09-17`. Before restoring it, read §10 of the plan:
> **Stop** on a Portainer stack is a `compose down` on a live container Komodo owns.

## Overview

Portainer is the container management UI and the deploy target for all other stacks. It does not poll this repository: [`deploy-stacks`](../../.github/workflows/deploy-stacks.yml) fires the webhook of each stack whose folder a push changed.

## Stack

- **Stack folder:** `stacks/portainer/`
- **Compose file:** `stacks/portainer/docker-compose.yml`

## Access

| Field       | Value                             |
| ----------- | --------------------------------- |
| URL (HTTPS) | `https://portainer.example.com` |
| Port        | 31015 (HTTPS only — HTTP disabled)|
| Tunnel port | 31016 (`--tunnel-port`) — **not published**; only Edge agents use it, and none are configured |
| Auth        | Local admin user                  |

## Volumes / data

| Container path         | Host path              | Purpose                  |
| ---------------------- | ---------------------- | ------------------------ |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket (required) |
| `/data`                | `/mnt/apps/portainer`  | Portainer config & state |

## GitOps setup

Each stack in `stacks/` is a Git-tracked stack in Portainer, **webhook-triggered with polling off**:

- A new folder is created as a stack by `deploy-stacks` on its first push — or, when its env lives
  in the vault, by `scripts/secrets.sh push <name>` from a workstation. Routing by name prefix:
  `a1-vps-*` → endpoint 5, `micro-vps-*` → 4, everything else → 3 (local). See the
  [webhook deploy runbook](../runbooks/setup-operations/portainer-webhook-deploy.md).
- By hand: **Stacks → Add stack → Repository**, branch `main`, compose path
  `stacks/<name>/docker-compose.yml`, GitOps updates → polling **off**, webhook **on**.

The original move of web-editor stacks to Git stacks is recorded in the
[Portainer GitOps migration runbook](../runbooks/setup-operations/portainer-gitops-migration.md)
(`scripts/portainer-migrate/`).

## Notes

- Portainer is deployed as a **TrueNAS custom app** — it can't manage itself, so it is not a Portainer GitOps stack. `stacks/portainer/docker-compose.yml` is still its source of truth, but **nothing applies it any more**: `deploy-portainer-app.yml` was deleted on 2026-09-17, because its weekly canary redeployed a Komodo-owned stack ([komodo-migration.md F26](../runbooks/setup-operations/komodo-migration.md#f26--portainers-canary-redeployed-a-komodo-owned-stack)). Portainer itself is being removed (§8 Phase 3, PR 8a).
- Running **portainer-ee** (Enterprise Edition), pinned to an explicit version + digest. **Not** `latest`: portainer-ee ships the LTS line on `latest`/`lts` and the short-term line on `sts`, so a `latest@sha256:` pin freezes the control plane on one build and hides every later release from Renovate.
- HTTP is disabled (`--http-disabled`); all access is HTTPS on port 31015.
- The compose sets `healthcheck: disable: True`. The health check reads `GET /api/system/status`
  instead of a container health state.

## Operations

> **Portainer is special**: it runs as a **TrueNAS custom app**, not a Portainer-managed stack (it can't manage itself). So its own lifecycle is driven through the **TrueNAS middleware**, by hand in the TrueNAS UI — never through Portainer stacks/webhooks.

### Restart / redeploy

- Config changes: **none.** Portainer is being removed, and no workflow applies its compose any more.
- Plain restart: TrueNAS UI → **Apps** → Portainer → **Restart** / **Stop** / **Start**.
- **Not** via Portainer stacks and **not** via the GitHub webhook flow.

### Upgrade

- **Do not upgrade it.** Renovate no longer opens portainer-ee PRs (`renovate.json`); close any open one unmerged. A merged bump would not be applied, and the health check would report the repo-vs-live drift.
- **Never** press **Update** in the TrueNAS or Portainer UI: it writes to a place git never sees, and the nightly health check reports the repo-vs-live drift it creates.

### Restore from backup

1. Stop the Portainer app in the TrueNAS UI.
2. Restore `apps/portainer` (all stack definitions, endpoints, env vars, users, settings) from a ZFS snapshot of `apps` or from Hetzner.
3. Start the app. If the config is lost rather than restored, re-add each stack from this repo (Repository stacks, webhook-on/polling-off — see [webhook runbook](../runbooks/setup-operations/portainer-webhook-deploy.md)).

### Common failures

- **Portainer down** → running containers are unaffected (Docker runs independently), but there's **no management UI and no webhook deploys**. Manage via TrueNAS / the host until it's back.
- **Tried to update it from inside Portainer** → it can't manage itself, and it is not being upgraded any more (see Upgrade).
- **Every `secrets.sh push` fails with HTTP 500 in ~200 ms and Portainer logs nothing** → the redeploy handler is cloning this **private** repo with empty credentials (`Unable to clone git repository directory` → GitHub 401), which is returned before any deployment. `secrets.sh push` replays the stack's stored `GitCredentialID` to work around it. Every stack is Komodo-owned now, so `push` no longer makes this call.
- **Login/cert issues on 31015** → HTTP is disabled (`--http-disabled`); access is HTTPS-only.
- **`Error response from daemon: layer does not exist` / won't start after reboot** → **two different causes, and they need opposite responses. Check which one before touching anything:**
  1. **The daemon is blind** (start here after a *reboot*). `sudo docker images` shows **0 images** and `docker ps -a` **0 containers**, but the blobs are on disk. dockerd started before its ZFS data-root (`/mnt/.ix-apps/docker`) was mounted and holds an empty in-memory store. **Do not `rmi`/`pull`/`prune`** — those writes flush the empty store to disk and destroy `image/overlay2/repositories.json` (this is exactly what happened 2026-07-13, wiping the tag map for 39 repos). Fix: `sudo systemctl restart docker` — everything comes back. Prevented at boot by [`docker-boot-guard.sh`](../runbooks/setup-operations/docker-image-prune.md), and the image guard now refuses to run in this state.
  2. **A layer blob really is gone** (`docker images` looks normal, only Portainer's image is broken) — historically from pruning an "unused" image in the Portainer UI. The [image guard](../runbooks/setup-operations/docker-image-prune.md) probes the layers and re-pulls at boot + hourly + after every prune, so this self-heals; to force it: `sudo /bin/sh /mnt/apps/scripts/nas/scripts/portainer-image-guard.sh`. Manual fix: `docker rmi -f <img>; docker system prune -f; docker pull <img>`.

  > If `repositories.json` was already clobbered, restore it from a ZFS snapshot — the tag map, not the blobs, is what's lost: stop docker, `cp /mnt/.ix-apps/docker/.zfs/snapshot/<snap>/image/overlay2/repositories.json` over the live one, start docker. `apps/ix-apps/docker` is snapshotted every 4h.

> **Never hand-prune images in the Portainer UI.** Removing an "unused" image can drop a layer blob a used image still shares → `layer does not exist` on the next start; that's what once kept the NAS down. Pruning is automated and paired with the layer-aware guard — see [Docker image prune + Portainer guard](../runbooks/setup-operations/docker-image-prune.md).

## Last updated

2026-09-17 — `deploy-portainer-app.yml` deleted (F26); no further upgrades.

2026-09-11
