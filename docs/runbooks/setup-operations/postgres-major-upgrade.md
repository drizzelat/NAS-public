# Runbook: Postgres major-version upgrade (dump → restore)

> **Status:** all four plain-Postgres stacks were moved to 18 with this procedure on 2026-07-02;
> the scope table records where each started. Kept for the next major, and for Immich's 19.

## Why

A Postgres **major** version (15 → 16 → 17 → 18) changes the on-disk data-directory
format. Swapping the image and restarting is **not** an upgrade: PG18 inspects the datadir,
sees it was initialised by an older major, and **refuses to start** —
`database files are incompatible with server ... was initialized by PostgreSQL <old>`.
The container then crash-loops and the service is down.

It does **not** corrupt anything — PG18 exits *before* touching the datadir — so the damage is
just downtime, and rollback to the old image brings the data back untouched. But the correct
path is to move the old datadir aside, let PG18 `initdb` a fresh cluster, and load a logical
`pg_dump` into it. That is exactly what [`postgres-dump.md`](../backup-restore/postgres-dump.md)
exists to enable.

### The 18+ datadir-layout change (why an image-only bump can't work here)

Separately from the major-version incompatibility, the official `postgres:18+` image **moved the
data directory**. It now stores data in a **major-version-specific subdirectory** and expects the
mount at `/var/lib/postgresql`, **not** `/var/lib/postgresql/data`. Our pre-18 stacks mount the old
`…/data` path, so even a *fresh* PG18 start against that mount aborts with:

```text
Error: in 18+, these Docker images are configured to store database data in a
format which is compatible with "pg_ctlcluster" ... using major-version-specific
directory names. ... place a single mount at /var/lib/postgresql
```

So the per-stack change is **not** a one-line image bump — the compose `db` service must be
restructured to the same pattern Immich already uses:

```yaml
    volumes:
      - /mnt/apps/<svc>/db:/var/lib/postgresql      # was: …/db:/var/lib/postgresql/data
    environment:
      PGDATA: /var/lib/postgresql/18/docker         # add this
```

Data then lands in `/mnt/apps/<svc>/db/18/docker` on the host.

> **Do NOT blind-merge the Renovate PRs** that bump these images (the bundled
> `postgres docker tag to v18` PRs). They change only the image tag, so they would crash-loop the
> DB **twice over**: wrong datadir layout *and* an un-migrated old cluster. Merging also deploys
> through Komodo straight onto the incompatible datadir. This runbook supersedes
> those PRs — migrate one DB at a time with the full compose change below, then close the PRs.

## Scope

Applies to the four plain-Postgres stacks with a **bind-mounted datadir**:

| Stack | Container | user / db | Datadir (host) | Current → target |
| --- | --- | --- | --- | --- |
| authentik | `authentik-postgresql-1` | `authentik` | `/mnt/apps/authentik/db` | 16-alpine → 18-alpine |
| mealie | `mealie-db` | `mealie` | `/mnt/apps/mealie/db` | 15 → 18 |
| paperless | `paperless-db` | `paperless` | `/mnt/apps/paperless/db` | 15 → 18 |
| gamevault | `gamevault-db` | `gamevault` | `/mnt/apps/mediaserver/config/gamevault/db` | 17 → 18 |

**Immich** is on 18 already and uses a different mechanism — see
[Immich (pgvecto / VectorChord)](#immich-pgvecto--vectorchord) below.

## Immich (pgvecto / VectorChord)

Immich runs `ghcr.io/immich-app/postgres:18-vectorchordX.Y.Z` with the datadir bind-mounted at
`/mnt/apps/immich` and `PGDATA=/var/lib/postgresql/18/docker` — already the 18+ layout.

Until 2026-08-21 the stack carried an `ixsystems/postgres-upgrade` service (`pgvecto_upgrade`,
`TARGET_VERSION: "18"`) wired as a `service_completed_successfully` gate on the database, so a
data-mutating in-place `pg_upgrade` helper ran on **every** deploy, with its digest bumped
unattended by Renovate. It was removed ([SEC-2](../../architecture-review-2026-08-20.md#sec-2--migration-container-in-the-normal-deploy-path)).
Deploys no longer touch the datadir.

Renovate's `18-vectorchordX.Y.Z` bumps stay inside major 18 and need nothing from this runbook.
When Immich eventually ships a **19** image, do it deliberately:

1. Pause auto-deploy (step 0 below) and take a verified dump (step 1) —
   `CONTAINER=immich-pgvecto-1`, `USER=immich`, `DB=immich`, `DUMPDIR=/mnt/apps/immich/dumps`.
2. Stop `immich-server-1` and `immich-machine-learning-1`, then `immich-pgvecto-1`.
3. Run the upgrade helper **once, by hand**, then delete it again — do not leave it in compose:

   ```sh
   sudo docker run --rm -u 999:999 \
     -e TARGET_VERSION=19 -e PGDATA=/var/lib/postgresql/19/docker \
     -e POSTGRES_PASSWORD="$POSTGRES_PW" \
     -v /mnt/apps/immich:/var/lib/postgresql \
     ixsystems/postgres-upgrade:<pinned-digest> /bin/bash -c /upgrade.sh
   ```

   Take a `zfs snapshot apps/immich@pre-pg19-$(date +%F)` first — this one *does* rewrite data.
4. Bump the compose image to the `19-vectorchord` pin and `PGDATA` to `/var/lib/postgresql/19/docker`,
   push, fire the webhook, verify, un-pause (step 8).

The dump/restore path below is the fallback if the helper fails: restore the step-1 dump into a
fresh 19 cluster. Only the pgvecto/VectorChord image can load that dump — the vector extension
must be present.

## Before you start

- All commands run **as `root` on the TrueNAS host**: `truenas_admin` is not in the `docker` group,
  so over SSH take a root shell (`sudo -i`) rather than prefixing each command with `sudo -n`.
- Do **one stack at a time**, verify it, then move to the next. Never batch.
- Watch the blast radius:
  - **authentik** is the SSO / forward-auth for other services — while it is down, anything
    behind it may 4xx. Pick a low-use window.
  - **gamevault-db** was in the old `mediaserver` stack at the 2026-07-02 run, so its redeploy
    bounced Jellyfin and the *arr suite too. Since the 2026-08-21 split it is in the `games` stack
    and bounces only GameVault.
- The [`deploy-stacks`](../../../.github/workflows/deploy-stacks.yml) health check can push an auto-rollback commit if a redeploy comes up unhealthy. That is your
  net if a step goes wrong — but drive the procedure deliberately, don't rely on it.

## Procedure (repeat per database)

Set these once per DB from the scope table, e.g. for authentik:

```sh
CONTAINER=authentik-postgresql-1          # DB container
APP="authentik-server-1 authentik-worker-1"  # app container(s) that write to it
USER=authentik
DB=authentik
DATADIR=/mnt/apps/authentik/db
DUMPDIR=/mnt/apps/authentik/dumps
STAMP=$(date +%Y%m%d-%H%M%S)
```

### 0. Pause auto-deploy (once, for the whole migration)

Two things deploy a merged compose change on their own, and either would race — and clobber — a
mid-restore migration:

- **The [`deploy-stacks`](../../../.github/workflows/deploy-stacks.yml) workflow.** It deploys and
  **health-checks** every stack a push changes, and **auto-rolls back** (reverts the stack's compose
  on `main` and deploys again) any stack that comes up unhealthy inside a ~4-min budget. Merge every
  migration commit with `[skip ci]` so it never runs.
- **Komodo's hourly `reconcile-owned` Procedure**, at `:23`. It deploys any Stack whose compose
  changed, with no health gate. Komodo → Procedures → `reconcile-owned` → turn its schedule off.
  Turn it back on at step 8.

While paused you drive each deploy by hand (step 4).

### 1. Take a fresh pre-migration dump (this is your rollback)

The nightly [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) already writes one, but take
a current one so no writes are lost:

```sh
STAMP=$(date +%Y-%m-%d_%H-%M)
mkdir -p "$DUMPDIR"
docker exec "$CONTAINER" pg_dump --clean --if-exists -U "$USER" "$DB" \
  | gzip -c > "$DUMPDIR/${DB}_premig_${STAMP}.sql.gz"
# sanity: non-trivial size and it gunzips cleanly
ls -lh "$DUMPDIR/${DB}_premig_${STAMP}.sql.gz"
gunzip -t "$DUMPDIR/${DB}_premig_${STAMP}.sql.gz" && echo "dump OK"
DUMP="$DUMPDIR/${DB}_premig_${STAMP}.sql.gz"
```

`pg_dump` is read-only — it cannot harm the running DB. Do **not** continue until this dump
verifies.

### 2. Stop the stack's services

Stop the app then the DB so nothing writes during the move. Over SSH as root:

```sh
sudo docker stop "$APP"        # app container(s) — for gamevault: gamevault-backend
sudo docker stop "$CONTAINER"  # the DB
```

### 3. Snapshot, move the old datadir aside, create a fresh target

```sh
sudo zfs snapshot "apps/<svc>@pre-pg18-${STAMP}"           # atomic belt-and-suspenders
sudo mv "$DATADIR" "${DATADIR}.pre18-${STAMP}"             # rename, do NOT delete — the rollback
sudo mkdir -p "$DATADIR" && sudo chown 999:999 "$DATADIR"  # fresh empty dir; postgres runs as 999
```

Renaming (not deleting) means rollback is a `mv` back. With the 18+ layout the new cluster is
created under `$DATADIR/18/docker`. **Pre-creating `$DATADIR` owned by 999:999 matters** — if it's
missing, Docker recreates the bind mount as `root:root` and `initdb` fails permission-denied.

### 4. Apply the PG18 compose change (image **and** datadir layout), then redeploy this stack only

A one-line image bump is **not** enough (see "18+ datadir-layout change" above). Edit only that
stack's `docker-compose.yml` db service:

- bump the `postgres:` image tag+digest to the `18.x` pin (digest from the matching Renovate PR),
- change the volume `…/db:/var/lib/postgresql/data` → `…/db:/var/lib/postgresql`,
- add `PGDATA: /var/lib/postgresql/18/docker` under `environment`.

Commit and push (one stack per commit — the paused workflow won't deploy it):

```sh
git commit -am "chore(<stack>): upgrade postgres to 18 with versioned datadir"
git push
```

Deploy **only this stack** yourself: Komodo → Stacks → `<stack>` → **Deploy**. That is
deterministic, and no auto-rollback can race the restore. If this commit changed `resources.toml`
too, execute the ResourceSync first, after reading its diff.

PG18 finds the empty `$DATADIR`, runs `initdb` into `18/docker`, and creates `$DB` + `$USER` from
the stack's `POSTGRES_*` env. Wait for healthy, then hold the app off the empty DB until restore:

```sh
until sudo docker exec "$CONTAINER" pg_isready -U "$USER" >/dev/null 2>&1; do sleep 3; done
sudo docker stop "$APP"
```

### 5. Load the dump into the fresh cluster

```sh
sudo bash -c "set -o pipefail; gunzip -c '$DUMP' \
  | docker exec -i $CONTAINER psql -q -v ON_ERROR_STOP=1 -U $USER -d $DB"
```

The dump is `--clean --if-exists`, so it drops/recreates objects before loading over the
freshly-initialised DB. `ON_ERROR_STOP=1` makes a bad load fail loudly instead of half-applying.

Clear the collation-version bookkeeping after a good restore (on same-glibc jumps it prints
`NOTICE: version has not changed` — also fine):

```sh
sudo docker exec "$CONTAINER" psql -U "$USER" -d "$DB" -c "ALTER DATABASE \"$DB\" REFRESH COLLATION VERSION;"
```

### 6. Start the app and verify

```sh
sudo docker start "$APP"
until sudo docker ps --filter "name=^/${APP%% *}$" --format '{{.Status}}' | grep -q healthy; do sleep 3; done
```

- DB row counts / key tables look right:
  `sudo docker exec "$CONTAINER" psql -U "$USER" -d "$DB" -c "\dt+"`
- App healthy + no errors in its logs; the app should log its migrations as already at head
  (mealie: "Database connection established"; paperless: "No migrations to apply").
- Exercise it: **authentik** → log in + an OIDC login into one app; **mealie** → open a recipe;
  **paperless** → search a document + a consume; **gamevault** → library loads.

### 7. Clean up (only after it is proven good — wait a few days)

```sh
sudo rm -rf "${DATADIR}.pre18-${STAMP}"
sudo zfs destroy "apps/<svc>@pre-pg18-${STAMP}"
```

Then close the corresponding Renovate PR (the image is already on 18 via your commit).

### 8. Un-pause auto-deploy

After **all** migrated stacks are verified, turn the `reconcile-owned` Procedure's schedule back
on. Later pushes deploy through `deploy-stacks` as usual.

## Rollback

If PG18 fails to init/restore, or the app misbehaves — the old datadir was only renamed and PG18
never touched it, so recovery is clean:

1. `sudo docker stop "$APP" "$CONTAINER"`.
2. Restore the old datadir:

   ```sh
   sudo rm -rf "$DATADIR"
   sudo mv "${DATADIR}.pre18-${STAMP}" "$DATADIR"
   ```

3. Revert the compose commit (`git revert <sha> && git push`) so the stack goes back to the old
   image **and** the old `…/data` mount, then re-fire the stack webhook.
4. Confirm the service is back.

Worst case (old datadir also lost) restore the pre-migration dump from step 1, or roll the whole
dataset back to the `@pre-pg18-${STAMP}` ZFS snapshot.

## Notes

> **Lessons from the 2026-07-02 run (all four migrated this way):**
>
> - **Datadir uid differs by image.** The Debian `postgres` images run as uid **999**; the
>   **alpine** image (authentik) runs as uid **70**. Don't hard-code the chown of the fresh
>   `$DATADIR` — capture the old dir's owner first (`stat -c '%u:%g'`) and reuse it.
> - **Apps without a `depends_on: condition: service_healthy` gate race the restore.** mealie /
>   paperless / gamevault wait for the DB healthcheck, so a quick `docker stop "$APP"` after the DB
>   comes up is enough. **authentik's server/worker have no such gate** — they connect to the
>   fresh empty DB in seconds and run their migrations, and `restart: unless-stopped` keeps
>   resurrecting them, so `docker stop` won't hold. A `--clean` dump then fails to DROP the
>   app-created schema (`cannot drop constraint … because other objects depend on it`) and
>   `ON_ERROR_STOP` aborts mid-restore. For such apps: `docker rm -f` the writers, then
>   `DROP DATABASE` / `CREATE DATABASE` for a pristine target, restore, then recreate the writers.
> - **Recreating force-removed containers:** press **Deploy** on the Stack in Komodo. It runs
>   `compose up`, which recreates missing containers on an unchanged commit. The Portainer webhook
>   this runbook used until 2026-09-17 no-oped on an unchanged commit and needed a trivial new one.

- **alpine vs glibc:** authentik stays alpine→alpine and the others stay glibc→glibc, so the
  collation *provider* doesn't change within a service — only the version string bumps (handled
  by the `REFRESH COLLATION VERSION` above). Do not cross alpine↔non-alpine during this upgrade.
- **Application support:** confirm each app supports PG18 before starting (e.g. mealie tracks a
  specific major). If an app pins an older major, keep that DB on its supported version and skip
  it here.
- For a very large DB where dump/restore downtime is unacceptable, use in-place `pg_upgrade`
  via a helper image (`ixsystems/postgres-upgrade`, as in the Immich section above). None of the
  DBs above are large enough to need it. Run such a helper **by hand** — never as a compose
  service in the deploy path.
</content>
