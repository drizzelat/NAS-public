# Runbook: Adding a new service

Follow these steps to add a Docker service deployed as a Komodo Stack.

## Steps

### 1. Create the stack folder

```text
stacks/<name>/
└── docker-compose.yml
```

Use an ordinary stack as a reference, e.g. `stacks/mealie/docker-compose.yml` (app + Postgres, dump
labels, a `proxy_*` network).

The name decides the host the stack is first created on: `micro-vps-<x>` → the micro VPS,
`a1-vps-<x>` → the A1, anything else → the NAS.

### 2. Write the compose file

- Do not hard-code secrets. Use environment variable placeholders (`${SECRET_VAR}`).
- Set `restart: unless-stopped` on all containers.
- Pin images `tag@sha256:digest` — never `latest`; Renovate keeps the pin current.
- Add `security_opt: [no-new-privileges=true]` and `deploy.resources.limits`, like the other stacks.
- Web-facing: join `proxy_<name>` (declared `external: true` at the bottom), keep everything else on
  the stack's own `default` network, and publish **no** host port.
- Add a `healthcheck:` where the image ships a probe tool — `deploy-stacks` gates on it.

### 3. Document the service

Copy `docs/services/_template.md` to `docs/services/<name>.md` and fill it in.

Add a row to `docs/services/README.md`.

### 4. Wire it into the edge (web-facing services)

Full detail: [network.md → Adding a New Stack](../../network.md#adding-a-new-stack) and
[caddy.md](../../services/caddy.md).

1. `stacks/caddy/docker-compose.yml` — add `proxy_<name>` to the `caddy` service's `networks:`
   **and** to the bottom `networks:` block.
2. `stacks/caddy/Caddyfile` — a site block for
   `<name>.example.com, https://<name>.example.com:8443`: `import lan_only http://<container>:<port>`
   for a LAN-only service, or the `crowdsec` + `appsec` + `reverse_proxy` form the public vhosts use.
3. Add the hostname to the access-control list in `docs/network.md` **and** to the matching `env:`
   list in [`edge-access-policy.yml`](../../../.github/workflows/edge-access-policy.yml) —
   `LAN_ONLY_HOSTS` or `PUBLIC_HOSTS`. A hostname missing from that workflow is never asserted,
   which is the whole failure mode it exists to catch. A public one additionally needs a `map`
   entry in [`stacks/micro-vps-ingress/`](../../../stacks/micro-vps-ingress/) plus a `config-rev`
   bump. Details: [edge access policy probe](edge-access-policy-probe.md).

No DNS record is needed: AdGuard and Cloudflare both cover `*.example.com` with a wildcard.

### 5. Update the network map and storage docs

- Any LAN-exposed port → the ports table in `docs/network.md`; a new Docker network → its networks
  table.
- Host bind mounts → the mount table in `docs/storage.md`. Give the service's state its own
  `apps/<name>` **leaf** dataset: the cloud-sync chain carries every `apps` leaf offsite by itself,
  but skips parent datasets and plain directories. A new `data` leaf needs adding to `DATA_INCLUDE`
  in [`cloudsync-chain.sh`](../../../scripts/cloudsync-chain.sh) — see the
  [backup runbook](../backup-restore/backup.md).

`python3 .github/scripts/docs-drift.py` checks the service doc, ports and mounts before you push.

### 6. Declare it in Komodo, secrets, then deploy

In the same PR as the folder:

- **A `[[stack]]` entry** in [`komodo/resources.toml`](../../../komodo/resources.toml). Copy a
  neighbour's, and keep these three fields: `server` (which host it runs on),
  `project_name = "<name>"` written out, and `destroy_before_deploy = false`. A derived project name
  can silently duplicate a stack (komodo-migration.md F13).
- **The env, as Variable names.** List the stack's env as `KEY=[[<NAME>__<KEY>]]` in `environment`.
  Values never go in the file.
- **Ownership.** Add the name to [`komodo/owned-stacks`](../../../komodo/owned-stacks) and to the
  `reconcile-owned` pattern. `check-owned.sh` fails the PR if the two differ.

**Env** → CI holds no vault key, so do this from the workstation **before merging**:

1. `scripts/secrets.sh edit <name>` — writes `secrets/portainer-env/<name>.env` and locks it.
   Commit `secrets.enc/portainer-env/<name>.env.age` in the PR.
2. `scripts/secrets.sh komodo-vars <name>` — writes the Komodo Variables the entry names.

**Merge.** `deploy-stacks` creates the Komodo Stack through a sync filtered to it, adds it to
`reconcile-owned`, deploys it and health-checks it. A Variable still missing stops the run with the
command to run. Rehearse first with
`gh workflow run deploy-stacks.yml -f stacks=<name> -f komodo_dry_run=true` after merging with `[skip ci]`.

Web-facing: the `caddy` change must land in the same push or earlier, so `proxy_<name>` exists
before the stack starts. Background: [secret-sync](secret-sync.md) and the
[deploy-stacks runbook](deploy-stacks.md).

> If the runner is offline, create and deploy it from Komodo by hand: execute the ResourceSync
> after reading its diff, then press **Deploy** on the Stack.

### 7. Add its database to the nightly dump (any DB — no exceptions)

**Every service that runs its own database gets a logical dump.** A ZFS snapshot of a
live DB is only crash-consistent; the logical dump is the safe, version-independent
restore path.

Nothing outside the stack needs editing —
[`scripts/pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) discovers its targets
from Docker labels. Put these on the **database service** in your compose file:

```yaml
    labels:
      nas.backup.dump: "true"
      nas.backup.user: <db-user>
      nas.backup.db: <db-name>
      nas.backup.dir: /mnt/<pool>/<rel>/dumps
      # nas.backup.engine: mariadb   # omit for Postgres
```

- `nas.backup.dir` **must live inside a leaf dataset that cloud sync carries** — for a stack with
  child datasets, that is one of the children or a `dumps` dataset of its own, not the parent.
  The `dumps/` subdir itself is created by the script.
- Engine: omit `nas.backup.engine` for Postgres (`pg_dump`); use `mariadb` for
  MariaDB/MySQL (`mariadb-dump`, which reads the container's own
  `MARIADB_ROOT_PASSWORD`, so `nas.backup.user` is ignored).

After the stack deploys, confirm the container carries the label and take one dump by
hand — the cron runs the script straight out of the auto-pulled on-host clone, so there
is nothing to copy:

```sh
sudo docker ps -a --filter label=nas.backup.dump=true --format '{{.Names}}'
sudo /bin/sh /mnt/apps/scripts/nas/scripts/pg-dump-backup.sh
```

Then add the DB to the table in the [Postgres dump runbook](../backup-restore/postgres-dump.md).

### 8. Monitoring

Add a Kuma monitor ([kuma-monitors](kuma-monitors.md)) — on the A1 instance too if the service is
public — and, if useful, a Homarr tile.

### 9. Commit

```bash
git add stacks/<name>/ docs/services/<name>.md docs/services/README.md docs/network.md docs/storage.md
# web-facing: also stacks/caddy/ and .github/workflows/edge-access-policy.yml (+ stacks/micro-vps-ingress/ if public)
git commit -m "feat(stacks): add <name>"
git push
```
