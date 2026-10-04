# Service: Komodo Core

## Overview

Komodo Core is the control plane that deploys the estate's compose stacks. Core holds the resource
model and the UI/API; it never runs `docker compose` itself. That is done by a **periphery** agent on
each host, which is a separate stack on purpose ([rules](#peripheries-are-hand-applied)).

It deploys the 28 stacks in [`komodo/owned-stacks`](../../komodo/owned-stacks) (six on the A1, two on
the micro VPS, 20 on the NAS) through CI, plus `github-runner` through its own Procedure and itself.
That is 30 Komodo Stacks.

## Stack

- **Stack folder:** `stacks/komodo/`
- **Compose file:** `stacks/komodo/docker-compose.yml`

| Container | Role |
| --------- | ---- |
| `komodo-mongo` | Core's database. MongoDB, which Komodo's built-in dated backup targets |
| `komodo-core` | UI, API, webhook listener, resource model |

## Access

| Field | Value |
| ----- | ----- |
| URL | `https://komodo.example.com`, **LAN-only**, through Caddy over `proxy_komodo` |
| Port | 9120 (container). No host port |
| Auth | Local admin only, passkey 2FA (Bitwarden). No Authentik, now or later: the control plane must not depend on a stack it deploys |

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/data/db` | `/mnt/apps/komodo/mongo/db` | MongoDB data |
| `/data/configdb` | `/mnt/apps/komodo/mongo/configdb` | MongoDB config server data |
| `/config/keys` | `/mnt/apps/komodo/keys` | Core's key pair; peripheries trust its public key |
| `/backups` | `/mnt/apps/komodo/backups` | Core's dated database backups (daily procedure, 01:00) |

Everything lives under `/mnt/apps/komodo`, dataset `apps/komodo`, never under `/etc`: a TrueNAS
update boots a new boot environment and `/etc` goes with it.

## Environment variables

Set from the age vault (`secrets.enc/stack-env/komodo.env.age`). Never in the compose file.

| Variable | Description |
| -------- | ----------- |
| `KOMODO_DATABASE_USERNAME` | Mongo root user, also what Core logs in with |
| `KOMODO_DATABASE_PASSWORD` | Mongo root password |
| `KOMODO_JWT_SECRET` | Signs UI/API sessions. Random, 32+ chars |
| `KOMODO_WEBHOOK_SECRET` | HMAC secret for `/listener/github/...`. Random, 32+ chars |
| `KOMODO_INIT_ADMIN_USERNAME` | Seeds the first admin on an empty database; ignored afterwards |
| `KOMODO_INIT_ADMIN_PASSWORD` | Same. The real admin password is in Bitwarden with the passkey |

Change one with `scripts/secrets.sh edit komodo`, never `lock`, which re-encrypts every file.
`KOMODO_DATABASE_*` only take effect on an **empty** Mongo data directory; changing them later
needs a Mongo user change first.

Two more keys sit in the same file and never reach Core, because nothing references them:

| Variable | Description |
| -------- | ----------- |
| `KOMODO_API_KEY` | API key `Claude access (repo)` on the admin user, **expires 2027-03-24**. For scripted API calls, which password login can no longer do behind 2FA. Rotate before then: a new key under **API Keys** at `/profile` (the API cannot mint one without the passkey session), `scripts/secrets.sh edit komodo`, then delete the old key |
| `KOMODO_API_SECRET` | Its secret |

Send them as the `X-Api-Key` and `X-Api-Secret` headers on `POST /{read|write|execute}/<Type>`. To
revoke, delete the key under **API Keys** at `/profile`, then remove both lines with
`scripts/secrets.sh edit komodo`.

## Dependencies

- `proxy_komodo`, defined in `stacks/caddy` like every other `proxy_*` network.
- A periphery on each host, deployed by hand as its own stack, never by Komodo:
  [nas-periphery](nas-periphery.md), [a1-vps-periphery](a1-vps-periphery.md),
  [micro-vps-periphery](micro-vps-periphery.md), [runner-vm-periphery](runner-vm-periphery.md).

## Notes

- **An unauthenticated Mongo is the failure mode to watch.** The Mongo root user is created from
  `MONGO_INITDB_ROOT_*` on the *first* start against an empty data directory. Start it with those
  unset and it initialises with no auth at all and listens on the stack network; the upstream
  template does exactly that when started without `--env-file`. So the Mongo healthcheck passes only
  when mongod answers **and** refuses an unauthenticated `listDatabases`. `core` waits for
  `service_healthy`, so a wide-open Mongo never gets a Core.
- **`${VAR:?}` is not used**, although it would fail even earlier. `compose-validate` runs
  `docker compose config` with no env, and a required variable fails that check.
- **Self-deploy works, and its record says it failed.** Deploying this stack from Komodo restarts
  Core mid-command. The periphery finishes the job and Core is back in ~2 s on the new config, but
  the update record reads `success=false`, "Komodo shutdown during execution". Check the containers,
  not the record.
- **`komodo.skip` on Mongo** stops Komodo's "stop all containers" action from taking down its own
  database.
- **The default procedures are declared.** A fresh Core creates `Backup Core Database` (01:00),
  `Global Auto Update` (03:00) and `Rotate Server Keys` (06:00), in Core's local time. All three are
  in `resources.toml`. `Global Auto Update`'s schedule is off, because it is a deploy path outside
  review; the other two run.

## Operations

> **Deployed by Komodo itself, never by CI.** `komodo` is not in `komodo/owned-stacks`, so
> `deploy-stacks` only logs a notice when its folder changes, and no GitHub webhook points at Komodo.
> The Procedure `deploy-komodo` deploys a merged change within the hour
> ([below](#komodo-deploys-itself-hourly)). A Variable change is not a compose change: after
> `komodo-vars komodo`, press Deploy on the Stack (or `execute/DeployStack`).

### Resources: the ResourceSync

Servers, the Repo, every Stack and the `reconcile-owned`, `deploy-runner` and `deploy-komodo` Procedures come from
[`komodo/resources.toml`](../../komodo/resources.toml) through the ResourceSync `komodo-resources`.
It has `delete` and `managed` off and excludes Variables and user groups, so it never removes anything
it does not declare, the `komodo` Stack included. **Nothing executes it automatically.** After a
change to resources.toml merges: `write/RefreshResourceSyncPending`, read the pending diff in the UI
or through `read/GetResourceSync`, then `execute/RunSync`. Declaring a Stack deploys nothing: polling
and `auto_update` are off on every one. CI runs only the filtered syncs for a new stack
([below](#ci-creates-new-stacks-through-a-filtered-sync)).

Each Stack's env comes from Komodo Variables named `<STACK>__<KEY>`, written from the vault by
`scripts/secrets.sh komodo-vars <stack>` ([secret-sync.md](../runbooks/setup-operations/secret-sync.md)).

### How an owned stack deploys

- **A merged change deploys through Komodo.** `deploy-stacks` runs on the self-hosted runner, in the
  runner VM. `fire-webhooks.sh` sends `execute/DeployStack` for an owned stack, waits for it to go
  idle first ([a busy Stack drops a request](#a-busy-stack-drops-a-deploy)), and follows the update
  record to the end. `verify-healthy.sh` then judges health; an unhealthy stack is rolled back by a
  revert PR that deploys like any other merge ([deploy-stacks runbook](../runbooks/setup-operations/deploy-stacks.md)).
- **Four Stacks mount config from Komodo's clone and check it in `post_deploy`**
  ([rule](#config-mounts-come-from-komodos-clone)):
  - `caddy` compares the mounted Caddyfile with the clone's, then runs `caddy reload`.
  - `authentik`, `observability` and `files` run
    [`scripts/komodo/mount-matches.sh`](../../scripts/komodo/mount-matches.sh) for each mount.

  A failure in either fails the deploy. A deploy is therefore what applies a Caddyfile change; no
  cron reloads Caddy.
- **`github-runner` is not owned** ([rule](#github-runner-deploys-between-jobs)).
- **CI removes nothing.** A removed folder gets a warning. The Stack is destroyed and deleted by hand
  ([deploy-stacks.md → Removing a stack](../runbooks/setup-operations/deploy-stacks.md#removing-a-stack)).
- **A lost deploy is picked up within the hour.** The Procedure `reconcile-owned` runs
  `BatchDeployStackIfChanged` at :23 every hour, UTC, over the owned stacks **named one by one**.
  With nothing pending it recreates nothing. Never widen it to a wildcard: a Stack that was never
  deployed counts as changed, so `*` would deploy every declared Stack at once, in parallel, with no
  health gate. `scripts/komodo/check-owned.sh` (in `compose-validate`) fails a PR whose pattern
  differs from `komodo/owned-stacks`. Its deploys get no health gate; the
  [deploy-state probe](../runbooks/setup-operations/deploy-state-probe.md) sees their result.
- **Dry run:** dispatch `deploy-stacks` with `komodo_dry_run: true`. Every Komodo read happens and
  the log says which create and `DeployStack` it would send.

The runner reaches Core through Caddy with `--resolve komodo.example.com:443:192.168.1.111`.
Public DNS sends the name to Cloudflare, which answers 525.

### Credentials

**Deploy:** the service user `deploy-stacks` has three grants:

- **Execute plus Inspect on Stacks.** It can deploy, stop or destroy a Stack, and read a Stack
  container's health log.
- **Execute on the one ResourceSync `komodo-resources`**, for creating new stacks.
- **Nothing else.** It cannot change a Stack's config, see a Server, or read a secret Variable
  (non-admins get `#` masks, though they see the names).

Inspect shows a container's environment, so `verify-healthy.sh` pipes it straight into `jq`. The
sync grant means a commit on `main` can make CI apply any `[[stack]]` entry it adds. That is the
trust level a compose change on `main` already has. Its API key `github-actions deploy-stacks` is
only in the repo secrets `KOMODO_DEPLOY_API_KEY` / `KOMODO_DEPLOY_API_SECRET`. To rotate it, mint a
new key for the user as admin (`write/CreateApiKeyForServiceUser`), pipe it into `gh secret set`,
then delete the old one.

**Read:** the service user `probe-read` has **Read on Servers and Stacks, plus Inspect on Servers**,
and Read on the one ResourceSync `komodo-resources`, for the probe's pending-changes check. Nothing
else.

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

### Servers

Matching the `[[server]]` entries in [`komodo/resources.toml`](../../komodo/resources.toml):

| Server | Address | Notes |
| ------ | ------- | ----- |
| `nas` | `https://192.168.1.111:8120` | |
| `micro-vps` | `https://100.64.0.12:8120` | tailnet |
| `a1-vps` | `https://100.64.0.13:8120` | tailnet |
| `runner-vm` | `https://192.168.1.34:8120` | the [runner VM](../runbooks/setup-operations/runner-vm.md) on the NAS |

All four with `auto_prune: false`: Komodo's default is a daily image prune on every host, and image
pruning is done by [docker-image-prune](../runbooks/setup-operations/docker-image-prune.md) instead.

### Restart / redeploy

From Komodo, as the `komodo` Stack. When Core is down, the bootstrap's `up -d` below is the path; it
also works from the periphery's clone at `/mnt/apps/komodo/repos/nas/stacks/komodo`, where Komodo
keeps a `.env` it wrote from the Variables. Core down does not mean estate down: containers keep
running, only deploys stop.

### Upgrade

Renovate bumps both images by digest. Read the release notes for a Komodo **minor**: Core and every
periphery move together, because a v2 minor can change the Core–periphery transport. Renovate groups
the images on a `control-plane` rule and holds them back from the merge sweep. Mongo stays on the 8.0
major line: `renovate.json` caps it to `8.0.x`. Minor lines (8.2, 8.3) cannot be skipped, so leaving
8.0 means snapshotting `apps/komodo` and doing one binary upgrade plus an FCV bump per hop.

### Restore from backup

1. Stop the stack.
2. Restore `apps/komodo` from a ZFS snapshot, or restore the newest dated backup from
   `/mnt/apps/komodo/backups`.
3. Start the stack.

Core's key pair (`keys/`) is not in the offsite backup (only `backups/` is a leaf). A new key means
rewriting `core.pub` on all four hosts.

### Bootstrap from nothing

`apps/komodo` and its child leaf `apps/komodo/backups` are datasets (`midclt call
pool.dataset.create`); `mongo/db`, `mongo/configdb` and `keys` (0700) are directories inside the
parent. From the workstation, in the repo root, after the change has reached the on-NAS clone:

```sh
NAS="ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.1.111"
# The env never touches the workstation's disk in plaintext, and only exists on the NAS for the up.
git show origin/main:secrets.enc/stack-env/komodo.env.age \
  | scripts/.bin/age -d -i secrets/age-key.txt \
  | $NAS 'sudo -n sh -c "umask 077; cat > /root/komodo.env"'
$NAS 'cd /mnt/apps/scripts/nas/stacks/komodo \
  && sudo -n docker compose -p komodo --env-file /root/komodo.env up -d \
  ; sudo -n shred -u /root/komodo.env'
$NAS 'sudo -n docker inspect komodo-mongo --format "{{.State.Health.Status}}"'   # must be healthy
```

`-p komodo` has to match the Komodo Stack's `project_name`
([rule](#the-project-name-is-load-bearing)). The first start writes
`/mnt/apps/komodo/keys/core.{key,pub}`; every periphery trusts that `core.pub`. Then the
peripheries, NAS first, each per its own doc; each VPS gets `core.pub` written to
`/etc/komodo/keys/core.pub` before its first start.

## Rules

Measured behaviour of Komodo v2 that the scripts and `resources.toml` depend on. Code comments point
here.

### The project name is load-bearing

Komodo adopts running containers by compose project name alone. A different project name on a
service **without** `container_name:` silently starts a second copy next to the first, exit 0, no
warning. `authentik` and `immich` are the dangerous ones: no host port to collide, `external: true`
proxy networks, and Caddy addressing them by compose-generated name (`authentik-server-1`,
`immich-server-1`). So every `[[stack]]` writes `project_name` out, equal to the stack name, and a
change to a project name is a Caddyfile change in the same commit.

### resources.toml entry rules

- `project_name` equals the stack name, written out (above).
- `destroy_before_deploy = false` everywhere; above all on `caddy`, whose `compose down` would try
  to take the `proxy_*` networks every web stack joins.
- `extra_args` is never set.
- `environment` names Komodo Variables, never values: `KEY=[[<STACK>__<KEY>]]`, for example
  `PG_PASS=[[AUTHENTIK__PG_PASS]]`.
- `komodo` and the four peripheries are deliberately absent.
- **A misspelt field is dropped silently.** Review a changed entry in the sync's pending view, not
  only in the TOML.

### A busy Stack drops a deploy

A deploy request that arrives while the Stack is still deploying is refused. The only trace is a
Core log line, `ERROR: Resource is busy`; the update record says `InProgress success=true` until the
next Core restart relabels it. So `fire-webhooks.sh` waits for idle before sending, and
`reconcile-owned` is the backstop for anything lost. `DeployStackIfChanged` with nothing pending
recreates nothing and writes no update record.

### Config mounts come from Komodo's clone

`caddy`, `authentik`, `observability` and `files` bind-mount config **directories** out of
`/mnt/apps/komodo/repos/nas`. Two traps:

- **Mount the directory, never the file.** Komodo pulls in place (`git pull --rebase --force`);
  a single-file bind mount keeps the old inode and shows stale content.
- **A reload alone proves nothing.** A pull can return the previous result when the same clone was
  pulled under 5 s ago, and a re-clone (Repo rename, hand clean-up) leaves a directory mount on the
  deleted directory, where `caddy reload` still exits 0. So each `post_deploy` compares what the
  container sees with the clone, and `komodo_check_commit` in
  [`scripts/komodo/lib.sh`](../../scripts/komodo/lib.sh) checks the Stack deployed a commit at or
  after the one the run was for.

`/mnt/apps/scripts/nas`, the cron clone, stays separate on purpose: host scripts must keep running
while the control plane is down ([nas-repo-autopull](../runbooks/setup-operations/nas-repo-autopull.md)).

### CI creates new stacks through a filtered sync

`RunSync` accepts a `resource_type` and `resources` filter and needs only Execute on the
ResourceSync. With a filter set it skips Variables and user groups, and the sync has `delete` off.
So a new owned stack is two filtered syncs, one for its Stack and one for `reconcile-owned`, then the
normal `DeployStack` with the health gate. A Variable the entry names but Komodo lacks stops the run;
run `secrets.sh komodo-vars` before merging.

### DestroyStack is compose down

`DestroyStack` is `docker compose -p <project> down`: containers removed, and networks the stack
defines survive only while another stack holds an endpoint. CI never calls it. Removing a stack is a
hand job ([deploy-stacks.md → Removing a stack](../runbooks/setup-operations/deploy-stacks.md#removing-a-stack)).
Komodo also never passes `--remove-orphans`: a service deleted from a compose file keeps running
until removed by hand.

### Peripheries are hand-applied

Each periphery is the transport its own Server deploys through; recreating it from Komodo drops the
connection mid-command. So the four `*-periphery` stacks are repo-tracked and digest-pinned but
applied over SSH, and are absent from `owned-stacks` and `resources.toml`. Start one only with
`PERIPHERY_CORE_PUBLIC_KEYS` set: without it an inbound periphery is an unauthenticated Docker
socket on `:8120`. The NAS periphery runs the host's compose plugin instead of the bundled one
([nas-periphery](nas-periphery.md)). An edit nobody applied shows in check 10 of the
[deploy-state probe](../runbooks/setup-operations/deploy-state-probe.md#check-10-which-compose-computes-the-hash),
which compares each container's compose config hash with its repo file.

### github-runner deploys between jobs

`github-runner` hosts the deploy job, so CI never deploys it. It is a Komodo Stack on `runner-vm`,
off `owned-stacks`. Its Procedure `deploy-runner` runs `DeployStackIfChanged` on it hourly at
`:53`, and the Stack's `pre_deploy`
([`runner-idle.sh`](../../scripts/komodo/runner-idle.sh)) waits until no job is running. Accepted
risk: a job can start in the seconds between the idle check and the recreate. No health gate, no
rollback ([github-runner.md](github-runner.md#deploy-path)); a broken runner bump is recovered by
merging its revert in GitHub's UI.

### Komodo deploys itself hourly

The Procedure `deploy-komodo` runs `DeployStackIfChanged` on the `komodo` Stack hourly at `:08` UTC.
Before 2026-09-30 nothing did: on 2026-09-23 Core and Mongo ran without the log cap for hours after
every other stack had it.

- **A real change takes two runs.** The first recreates Core mid-command, so Core never writes the
  result: the record reads `success=false` ("Komodo shutdown during execution") and the Stack's
  deployed contents stay old. The next run sees the same difference, runs `compose up`, finds the
  containers current, recreates nothing, and records the new contents. Seen live: the 2026-09-21
  self-deploy left the deployed commit at 09-15's.
- **Judge it by the containers**, not the record: image digests, and `Created` on `komodo-core`.
- **Core is away ~2 s** during the recreate. A `deploy-stacks` run in that window loses its update
  record and goes red. Core changes are hand-merged, so merge them when no other deploy is running.
- **`destroy_before_deploy` must stay off** on this Stack. With a `down` first, Core would remove
  itself and nothing would bring it back.
- The peripheries cannot be deployed this way: a periphery running its own recreate kills the
  process running the command ([above](#peripheries-are-hand-applied)).

### Secret Variables: masking and history

- **A secret Variable is masked everywhere in the logs**, as `<STACK__KEY>`. A short common value
  (the Mongo username `komodo`) garbles every log line that contains it, so such values are not
  secret Variables.
- **Update history keeps Variable values in plaintext.** `CreateVariable` and
  `UpdateVariableValue` log the value, readable by admins, and there is no API to prune update
  records. Treat Core's database and its backups as holding every secret the vault holds.

### List calls stop at 50

Paginated list calls return 50 results when the request names no `limit`, with no error and no
`next` field. `ListAllContainers` returned 50 of 77. Every list call in this repo passes
`"limit":0`. `ListDockerContainers` per Server is not paged.

### Predicting a deploy

Render the stack with the periphery's own compose and compare it with the running containers. It
prints `Running` or `Recreate` per container:

```sh
docker exec -w /mnt/apps/komodo/repos/nas/stacks/<stack> komodo-periphery \
  docker compose -p <stack> -f docker-compose.yml --env-file /dev/shm/<stack>.env up -d --dry-run
```

Put the env in a tmpfs file inside the periphery and remove it afterwards; `--env-file /dev/stdin`
does not work, because compose reads the file more than once. `config --hash '*'` is not a
substitute: it cannot resolve `network_mode: service:<name>`, so it reports every `downloads`
service behind `gluetun` as changed.
