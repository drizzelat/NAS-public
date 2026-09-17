# Service: Komodo Core

> **Phase 2 of the [Komodo migration](../runbooks/setup-operations/komodo-migration.md), done
> 2026-09-15.** Core deploys all 29 stacks in [`komodo/owned-stacks`](../../komodo/owned-stacks)
> (six on the A1, two on the micro VPS, 21 on the NAS) and its own. Portainer was removed on 2026-09-17
> (Phase 3; `qdirstat` was removed instead of adopted, F24). Phases 1 and 2 both started before start gate 6 closed (2026-09-18 08:32Z), by decision.

## Overview

Komodo Core is the control plane that replaces Portainer EE for deploying the estate's compose
stacks ([SVC-2](../architecture-review-2026-08-20.md#svc-2--portainer-ee--komodo)). Core holds the
resource model and the UI/API; it never runs `docker compose` itself. That is done by a
**periphery** agent on each host, which is a separate stack on purpose (F9, F12).

## Stack

- **Stack folder:** `stacks/komodo/`
- **Compose file:** `stacks/komodo/docker-compose.yml`

| Container | Role |
| --------- | ---- |
| `komodo-mongo` | Core's database. MongoDB, the documented backend (F3) |
| `komodo-core` | UI, API, webhook listener, resource model |

## Access

| Field | Value |
| ----- | ----- |
| URL | `https://komodo.example.com`, **LAN-only**, through Caddy over `proxy_komodo` |
| Port | 9120 (container). No host port |
| Auth | Local admin only, passkey 2FA (Bitwarden). No Authentik, now or later (§4 of the plan) |

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/data/db` | `/mnt/apps/komodo/mongo/db` | MongoDB data |
| `/data/configdb` | `/mnt/apps/komodo/mongo/configdb` | MongoDB config server data |
| `/config/keys` | `/mnt/apps/komodo/keys` | Core's key pair; peripheries trust its public key |
| `/backups` | `/mnt/apps/komodo/backups` | Core's dated database backups (daily procedure, 01:00) |

Everything lives under `/mnt/apps/komodo`, dataset `apps/komodo`, never under `/etc`: a TrueNAS
update boots a new boot environment and `/etc` goes with it (F4).

## Environment variables

Set from the age vault (`secrets.enc/portainer-env/komodo.env.age`). Never in the compose file.

| Variable | Description |
| -------- | ----------- |
| `KOMODO_DATABASE_USERNAME` | Mongo root user, also what Core logs in with |
| `KOMODO_DATABASE_PASSWORD` | Mongo root password |
| `KOMODO_JWT_SECRET` | Signs UI/API sessions. Random, 32+ chars |
| `KOMODO_WEBHOOK_SECRET` | HMAC secret for `/listener/github/...`. Random, 32+ chars |
| `KOMODO_INIT_ADMIN_USERNAME` | Seeds the first admin on an empty database; ignored afterwards |
| `KOMODO_INIT_ADMIN_PASSWORD` | Same. Change it in the UI and keep the real one in Bitwarden |

All six are in the vault (the four non-admin keys added 2026-09-15, generated at random). Change one
with `scripts/secrets.sh edit komodo`, never `lock`, which re-encrypts every file.
`KOMODO_DATABASE_*` only take effect on an **empty** Mongo data directory; changing them later
needs a Mongo user change first.

**The admin password is not these.** It was changed in the UI on 2026-09-15 and lives in Bitwarden
with the passkey. `KOMODO_INIT_ADMIN_PASSWORD` is the stale seed, read only when the database is empty.

Two more keys sit in the same file and never reach Core, because nothing references them:

| Variable | Description |
| -------- | ----------- |
| `KOMODO_API_KEY` | API key `Claude-access (repo)` on the admin user, no expiry. For scripted API calls, which password login can no longer do behind 2FA |
| `KOMODO_API_SECRET` | Its secret |

Send them as the `X-Api-Key` and `X-Api-Secret` headers on `POST /{read|write|execute}/<Type>`. To
revoke, delete the key under **API Keys** at `/profile`, then remove both lines with
`scripts/secrets.sh edit komodo`.

## Dependencies

- `proxy_komodo`, defined in `stacks/caddy` like every other `proxy_*` network (#360).
- A periphery on each host, deployed by hand as its own stack, never by Komodo (F12):
  [nas-periphery](nas-periphery.md), [a1-vps-periphery](a1-vps-periphery.md),
  [micro-vps-periphery](micro-vps-periphery.md), [runner-vm-periphery](runner-vm-periphery.md).

## Notes

- **An unauthenticated Mongo is the failure mode to watch.** The Mongo root user is created from
  `MONGO_INITDB_ROOT_*` on the *first* start against an empty data directory. Start it with those
  unset and it initialises with no auth at all and listens on the stack network. The upstream
  template does exactly that when started without `--env-file` (F15). So the Mongo healthcheck
  passes only when mongod answers **and** refuses an unauthenticated `listDatabases`. `core` waits
  for `service_healthy`, so a wide-open Mongo never gets a Core. Tested against the A1 eval: rc 0
  on the authenticated Mongo; rc 1 on a Mongo started with no credentials; rc 1 with mongod
  unreachable.
- **`${VAR:?}` is not used**, although it would fail even earlier. `compose-validate` runs
  `docker compose config` with no env, and a required variable fails that check.
- **Self-deploy works, and its record says it failed.** Deploying this stack from Komodo restarts
  Core mid-command. The periphery finishes the job: on the A1 eval, Core was back in ~2 s on the new
  config. The update record, though, reads `success=false`, "Komodo shutdown during execution".
  Check the containers, not the record (§5 item 7).
- **`komodo.skip` on Mongo** stops Komodo's "stop all containers" action from taking down its own
  database.
- **Default procedures exist without being declared.** A fresh Core creates three:
  `Backup Core Database` (01:00), `Global Auto Update` (03:00) and `Rotate Server Keys` (06:00).
  Servers also default to `auto_prune: true`, a daily image prune.

## Operations

> **Deployed by Komodo itself (F9), never by CI.** `komodo` is not in `komodo/owned-stacks`, so
> `deploy-stacks` only logs a notice when its folder changes. It is the
> Komodo Stack `komodo` (Server `nas`, linked Repo `nas`, `project_name = "komodo"`, env from the
> `KOMODO__*` Variables), self-managed since 2026-09-15. **No GitHub webhook points at Komodo**, and
> `komodo` is not in `komodo/owned-stacks`, so a merged change to it deploys only when you press
> Deploy on the Stack (or `execute/DeployStack`).
> Judge that deploy by the containers: its record reads `success=false` whenever Core recreates
> itself (F16).

### Resources: the ResourceSync

Servers, the Repo, every Stack and the `reconcile-owned` and `deploy-runner` Procedures come from
[`komodo/resources.toml`](../../komodo/resources.toml) through the ResourceSync `komodo-resources`.
It has `delete` and `managed` off and excludes Variables and user groups, so it never removes anything
it does not declare, the `komodo` Stack included. **Nothing executes it automatically.** After a
change to resources.toml merges: `write/RefreshResourceSyncPending`, read the pending diff in the UI
or through `read/GetResourceSync` (a misspelt field is dropped silently), then `execute/RunSync`.
Declaring a Stack deploys nothing: polling and `auto_update` are off on every one.

Each Stack's env comes from Komodo Variables named `<STACK>__<KEY>`, written from the vault by
`scripts/secrets.sh komodo-vars <stack>` ([secret-sync.md](../runbooks/setup-operations/secret-sync.md)).
Only the stacks adopted so far have theirs; write a stack's Variables just before adopting it.

### Adopted stacks (Phase 2)

A stack is Komodo's once its name is in [`komodo/owned-stacks`](../../komodo/owned-stacks) (§9 of the
plan). From then on:

- **A merged change deploys through Komodo.** `deploy-stacks` runs on the self-hosted runner, in the
  runner VM.
  `fire-webhooks.sh` sends `execute/DeployStack` for an owned stack, waits for the stack to go idle first (a busy stack drops the request, F16), and follows
  the update record to the end. `verify-healthy.sh` then judges health exactly as before, and its
  auto-rollback re-deploys an owned stack through Komodo.
- **Four Stacks mount config from Komodo's clone and check it in `post_deploy`** (CPX-2 #4a,
  2026-09-17):
  - `caddy` compares the mounted Caddyfile with the clone's, then runs `caddy reload`.
  - `authentik`, `observability` and `files` run
    [`scripts/komodo/mount-matches.sh`](../../scripts/komodo/mount-matches.sh) for each mount.

  A failure in either fails the deploy. A deploy is therefore what applies a Caddyfile change; no
  cron reloads Caddy any more.
- **`github-runner` is not owned** (since 2026-09-17, plan F27). It hosts the deploy job, so CI never
  deploys it. Its own Procedure `deploy-runner` runs `DeployStackIfChanged` on it hourly at `:53`, and
  the Stack's `pre_deploy` ([`runner-idle.sh`](../../scripts/komodo/runner-idle.sh)) waits until no job
  is running. No health gate, no rollback ([github-runner.md](github-runner.md#deploy-path)).
- **CI creates a new owned stack** (since 2026-09-17, plan F29). It runs two syncs filtered to single
  resources: first `RunSync` for the new Stack, then one for `reconcile-owned`. Then it deploys the
  Stack with the health gate.
  - Nothing else pending in `resources.toml` is applied by those syncs.
  - A Variable the entry names but Komodo lacks stops the run; run `secrets.sh komodo-vars` first.
- **CI removes nothing.** A removed folder gets a warning. The Stack is destroyed and deleted by hand
  ([deploy-stacks.md → Removing a stack](../runbooks/setup-operations/deploy-stacks.md#removing-a-stack)).
- **Portainer does nothing to it.** No workflow calls Portainer since 2026-09-17 (SVC-2 Phase 3,
  PR 6).
- **A lost deploy is picked up within the hour.** The Procedure `reconcile-owned`
  ([`komodo/resources.toml`](../../komodo/resources.toml)) runs `BatchDeployStackIfChanged` at :23
  every hour, UTC, over the owned stacks **named one by one**. It replaced Portainer's reconcile pass for
  them (F10, F16), and with nothing pending it recreates nothing. Never widen it to a wildcard: a
  Stack that was never deployed counts as changed, so `*` would adopt every Stack at once.
  `scripts/komodo/check-owned.sh` (in `compose-validate`) fails a PR whose pattern differs from
  `komodo/owned-stacks`. Its deploys get no health gate; the §1 probe sees their result.
- **Dry run:** dispatch `deploy-stacks` with `komodo_dry_run: true`. Every Komodo read happens and
  the log says which create and `DeployStack` it would send.

The runner reaches Core through Caddy with `--resolve komodo.example.com:443:192.168.178.111`.
Public DNS sends the name to Cloudflare, which answers 525.

**Credential:** the service user `deploy-stacks` (created 2026-09-15) has three grants:

- **Execute plus Inspect on Stacks** (Inspect added 2026-09-17). It can deploy, stop or destroy a
  Stack, and read a Stack container's health log.
- **Execute on the one ResourceSync `komodo-resources`** (added 2026-09-17), for creating new stacks
  (F29).
- **Nothing else.** It cannot change a Stack's config, see a Server, or read a secret Variable
  (non-admins get `#` masks, though they see the names).

Inspect shows a container's environment, so `verify-healthy.sh` pipes it straight into `jq`. The
sync grant means a commit on `main` can make CI apply any `[[stack]]` entry it adds. That is the
trust level a compose change on `main` already has. Its API key
`github-actions deploy-stacks` is only in the repo secrets `KOMODO_DEPLOY_API_KEY` /
`KOMODO_DEPLOY_API_SECRET`. To rotate it, mint a new key for the user as admin
(`write/CreateApiKeyForServiceUser`), pipe it into `gh secret set`, then delete the old one.

**Read credential:** the service user `probe-read` (created 2026-09-17) has **Read on Servers and
Stacks, plus Inspect on Servers**, and nothing else.

- **Used by:** `deploy-state-probe` and `nas-health-check`, through `nas-health-image-drift.sh`.
- **Why Inspect:** Komodo's container list carries no compose labels, so the probe inspects each
  container.
- **What Inspect costs:** it also shows every container's environment, secrets included. Treat the
  key as a secret reader.
- **Where the key lives:** the API key `github-actions probe-read` is only in the repo secrets
  `KOMODO_READ_API_KEY` / `KOMODO_READ_API_SECRET`. Rotate it like the deploy key.
- **What it cannot do:** it cannot deploy. An `execute/*` it sends still returns HTTP 200 and writes
  a failed update record, `User does not have required permissions`, so a refusal shows only in the
  record.

**Every list call needs `"limit":0`.** Komodo pages list results at 50 by default and says nothing:
`ListAllContainers` returned 50 of the estate's 77 containers (komodo-migration.md F32).
`ListDockerContainers` per Server is not paged.

**Taking a stack back to Portainer (§10)** is no longer possible: Portainer was removed on 2026-09-17.
Rolling a stack back is a revert through `deploy-stacks`.

### Bootstrap (once, by hand) — done 2026-09-15

`apps/komodo` and its child leaf `apps/komodo/backups` are datasets (`midclt call
pool.dataset.create`); `mongo/db`, `mongo/configdb` and `keys` (0700) are directories inside the
parent. From the workstation, in the repo root, after the merge has reached the on-NAS clone:

```sh
NAS="ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111"
# The env never touches the workstation's disk in plaintext, and only exists on the NAS for the up.
git show origin/main:secrets.enc/portainer-env/komodo.env.age \
  | scripts/.bin/age -d -i secrets/age-key.txt \
  | $NAS 'sudo -n sh -c "umask 077; cat > /root/komodo.env"'
$NAS 'cd /mnt/apps/scripts/nas/stacks/komodo \
  && sudo -n docker compose -p komodo --env-file /root/komodo.env up -d \
  ; sudo -n shred -u /root/komodo.env'
$NAS 'sudo -n docker inspect komodo-mongo --format "{{.State.Health.Status}}"'   # must be healthy
```

`-p komodo` has to match the Komodo Stack's `project_name` exactly, or its first self-deploy
duplicates the stack (F13). The first start writes `/mnt/apps/komodo/keys/core.{key,pub}`; every
periphery trusts that `core.pub`, so **regenerating Core's key means rewriting `core.pub` on all four
hosts**. The key is not in the offsite backup (only `backups/` is a leaf).

Then the peripheries, NAS first: [nas-periphery](nas-periphery.md), [a1-vps-periphery](a1-vps-periphery.md),
[micro-vps-periphery](micro-vps-periphery.md). Each VPS gets `core.pub` written to
`/etc/komodo/keys/core.pub` before its first start.

### Servers

Created through the API (`write/CreateServer`), matching the `[[server]]` entries in
[`komodo/resources.toml`](../../komodo/resources.toml):

| Server | Address | Notes |
| ------ | ------- | ----- |
| `nas` | `https://192.168.178.111:8120` | |
| `micro-vps` | `https://100.64.0.12:8120` | tailnet |
| `a1-vps` | `https://100.64.0.13:8120` | tailnet |
| `runner-vm` | `https://192.168.178.34:8120` | the [runner VM](../runbooks/setup-operations/runner-vm.md) on the NAS, added 2026-09-17 |

All four with `auto_prune: false`: Komodo's default is a daily image prune on every host, and
nothing should change on the hosts before Komodo owns the stacks (decided 2026-09-15). A fresh Core
also creates three Procedures on its own: `Backup Core Database` (01:00), `Global Auto Update`
(03:00, a no-op while no Stack exists) and `Rotate Server Keys` (06:00).

### Restart / redeploy

From Komodo, as the `komodo` Stack. When Core is down, the bootstrap's `up -d` above is the path; it
also works from the periphery's clone at `/mnt/apps/komodo/repos/nas/stacks/komodo`, where Komodo
keeps a `.env` it wrote from the Variables.

### Upgrade

Renovate bumps both images by digest. Read the release notes for a Komodo **minor**: Core and every
periphery should move together (F2). Mongo stays on the 8.0 major line: `renovate.json` caps it to
`8.0.x`. Minor lines (8.2, 8.3) cannot be skipped, so leaving 8.0 means snapshotting `apps/komodo`
and doing one binary upgrade plus an FCV bump per hop.

### Restore from backup

1. Stop the stack.
2. Restore `apps/komodo` from a ZFS snapshot, or restore the newest dated backup from
   `/mnt/apps/komodo/backups`.
3. Start the stack. The estate keeps running without Core: containers are unaffected, only
   deploys stop.

### Prerequisites (all done 2026-09-15)

- [x] Four more vault keys (above)
- [x] `apps/komodo` dataset, with `apps/komodo/backups` as its own leaf, and `docs/storage.md` rows
- [x] `proxy_komodo` in `stacks/caddy`, the LAN-only `komodo.example.com` vhost, `LAN_ONLY_HOSTS`
      and `network.md`, landed on its own and proven green first (#360: `edge-access-policy` and
      `deploy-state-probe` both green on it)
- [x] `stacks/{nas,a1-vps,micro-vps}-periphery/`, hand-applied (F4, F12)
- [x] `/mnt/apps/komodo/backups` in the Cloud Sync chain (F3): a new `apps` leaf joins it with no change
- [x] Renovate: `mongo` on the stateful rule, both Komodo images grouped on a `control-plane` rule,
      all three on `MERGE_SKIP_IMAGES`

## Last updated

2026-09-17 — `github-runner` on `runner-vm`, off `owned-stacks`, deployed by the `deploy-runner` Procedure (SVC-2 Phase 3, PR 11).

2026-09-17 — Server `runner-vm`, the runner VM's periphery (SVC-2 Phase 3, PR 10).

2026-09-15 — Phase 2: the ResourceSync, adopted-stack deploys through the runner, `reconcile-owned`, the `deploy-stacks` service user, the six A1 adoptions, and both micro VPS adoptions. `qdirstat` removed (F24). The 21 NAS adoptions (all `NO CHANGE`, F25) and the deferred `github-runner` path (#386).
