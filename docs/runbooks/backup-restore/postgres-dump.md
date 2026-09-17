# Runbook: Logical database backups (pg_dump / mariadb-dump)

## Why

The local snapshots and the offsite Hetzner push back up the **live DB data directory**
via an atomic ZFS snapshot. That is crash-consistent and normally restores cleanly, but a
logical dump is the safer, portable, version-independent restore path (and the only sane way
to restore a single table or move between DB major versions).

**Every service DB gets a logical dump — no exceptions.** The one script covers both engines:
Postgres via `pg_dump`, MariaDB/MySQL via `mariadb-dump --single-transaction`.

[`scripts/pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) writes one gzipped dump per DB into
a `dumps/` directory that already lives **inside a backed-up dataset**, so the nightly cloud sync
carries it offsite with no extra task.

Both dumpers are read-only against the database — they cannot corrupt a running service.

### A dump is only kept if it finished

The script is POSIX `sh`, which has no `pipefail`, so `dumper | gzip -c > file` reports
**gzip's** exit status and never the dumper's. A `pg_dump` killed mid-stream — tailnet
blip on the A1's remote dump, a container restart, OOM — still produces a perfectly valid
gzip of a partial dump. `gzip -t` cannot tell the difference, because the *container* is
intact; only the SQL inside is short.

So the script checks the dumper's own end marker before promoting `.tmp` to the real
name: `-- PostgreSQL database dump complete` for `pg_dump`, `-- Dump completed` for
`mariadb-dump`. No marker → the file is discarded and the failure is emailed, and
retention pruning is skipped that run, so a bad night can never delete good history.

The nightly health check asserts the same marker independently (check 10, `complete:`
line of the `dumps` verb) — see [nas-health-check](../setup-operations/nas-health-check.md).

## How a database opts in

**A database is backed up because its own compose file says so, not because a script remembers
it.** The script discovers targets at runtime from Docker labels
([STR-5](../../architecture-review-2026-08-20.md#str-5--dump-list-is-hardcoded-not-discovered));
until 2026-08-21 it carried a hardcoded container-name table, which is exactly why the Matrix
Synapse DB went unbacked-up and why moving a stack meant remembering to edit a path.

Add these to the **database service** in `stacks/<name>/docker-compose.yml`:

```yaml
    labels:
      nas.backup.dump: "true"                 # opts this container in
      nas.backup.user: mealie                 # DB user to dump as
      nas.backup.db: mealie                   # database name (comma-separate several)
      nas.backup.dir: /mnt/apps/mealie/dumps  # NAS dir the dump lands in
      # nas.backup.engine: mariadb            # omit for Postgres
```

`nas.backup.db` takes a comma-separated list when one container hosts several databases — the A1's
`matrix-postgres` uses `synapse,mautrix_whatsapp`, and each gets its own dump file. All of them are
dumped as `nas.backup.user`, so that role must be able to read every database listed.

`nas.backup.dir` must sit **inside a leaf dataset** so the 03:00 cloud sync carries it offsite —
the chain skips parent datasets, so a directory in a dataset that has children never leaves the
NAS. The script `mkdir -p`s the dir, so a missing dataset fails silently: RomM's dumps sat in the
`apps/romm` parent, local-only, until they got an `apps/romm/dumps` dataset on 2026-09-11. See
[backup.md](backup.md). The `user` label is ignored for MariaDB, which
authenticates as root with the container's own `MARIADB_ROOT_PASSWORD`.

Then redeploy the stack: labels are part of the service config, so the container is recreated and
the next 02:30 run picks it up. Nothing else to edit.

## Databases covered

Discovered, not configured — this table is documentation of the current result:

| Container                | DB / user   | Engine   | Dump dir                                       |
| ------------------------ | ----------- | -------- | ---------------------------------------------- |
| `authentik-postgresql-1` | authentik   | postgres | `/mnt/apps/authentik/dumps`                    |
| `immich-pgvecto-1`       | immich      | postgres | `/mnt/apps/immich/dumps`                       |
| `paperless-db`           | paperless   | postgres | `/mnt/apps/paperless/dumps`                    |
| `mealie-db`              | mealie      | postgres | `/mnt/apps/mealie/dumps`                       |
| `gamevault-db`           | gamevault   | postgres | `/mnt/apps/mediaserver/config/gamevault/dumps` |
| `romm-db`                | romm        | mariadb  | `/mnt/apps/romm/dumps`                         |
| `matrix-postgres` (**A1**) | synapse + mautrix_whatsapp / synapse | postgres | `/mnt/apps/a1-matrix/dumps` |

Confirm it any time with:

```sh
sudo docker ps -a --filter label=nas.backup.dump=true --format '{{.Names}}'
sudo docker -H ssh://a1-docker ps -a --filter label=nas.backup.dump=true --format '{{.Names}}'
```

Retention: 7 days of timestamped dumps per DB (`<db>_YYYY-MM-DD_HH-MM.sql.gz`), pruned by the
script.

## Guardrails against silent discovery

Discovery removes the "forgot to add it" failure mode and introduces the opposite one: a DB that
silently drops **out** of the set backs up nothing while the job still reports success. Two checks
close that:

- **Empty discovery is a hard error.** Zero labelled containers on any configured host fails the
  run and sends the alert mail, rather than reporting "All DB dumps OK" over an empty set.
- **Shrink detection.** Every fully successful run writes its discovered set to
  `/root/.local/state/nas-db-dump-discovered`. The next run errors on any entry from that file it
  can no longer find — so deleting a label, or a stack that never comes back after a rename, is
  caught within a day.

  A **deliberate** removal (a service is genuinely gone) therefore alerts once. Clear it with
  `sudo rm /root/.local/state/nas-db-dump-discovered`; the next good run rebuilds the file.

A container that is labelled but **not running** is reported as `SKIP` and fails the run, matching
the old behaviour for a missing container.

## Multiple hosts

The `HOSTS` list at the top of the script names the Docker endpoints to scan:

```sh
HOSTS="
nas|
a1|-H ssh://a1-docker
"
```

Each row is `name|docker -H value`; an empty value means the local daemon.

`a1-docker` is an SSH alias in the NAS root's `/root/.ssh/config` pointing at the Ampere A1 over
the tailnet, with a dedicated key that the A1 pins to a single forced command. `docker exec`
streams the dump back over that connection, so **`nas.backup.dir` is always a path on the NAS**
even for a remote database. Setup and restore: [a1-matrix-backup.md](a1-matrix-backup.md).

Adding another host is that one line plus the key work — nothing else in the script changes.

## Schedule it

The script needs Docker access, so it runs as **root on the TrueNAS host**: `truenas_admin` is not
in the `docker` group, and a cron entry should not depend on `sudo`. It's already scheduled
(TrueNAS cron id 2, daily **02:30**, before the 03:00 cloud-sync window in [backup.md](backup.md)).

The cron runs the script **straight out of the on-host repo clone** —
`/bin/sh /mnt/apps/scripts/nas/scripts/pg-dump-backup.sh` — which is auto-pulled from `main`
every 15 min. So editing this script and pushing is all it takes; no copy onto the host. See
[NAS repo auto-pull](../setup-operations/nas-repo-autopull.md).

## Restore

```sh
# stop the consuming Stack in Komodo first (Stop, never Destroy) if doing a full restore
gunzip -c /mnt/apps/authentik/dumps/authentik_<stamp>.sql.gz \
  | docker exec -i authentik-postgresql-1 psql -U authentik -d authentik
```

The dump uses `--clean --if-exists`, so it drops and recreates objects before loading.

For a **MariaDB** DB (e.g. RomM), stop the stack first, then load the dump back through the
DB container:

```sh
gunzip -c /mnt/apps/romm/dumps/romm_<stamp>.sql.gz \
  | docker exec -i romm-db sh -c 'exec mariadb -u root -p"$MARIADB_ROOT_PASSWORD"'
```

The dump was taken with `--databases`, so it recreates the `romm` schema before loading.

## Verifying a change to the script

It runs as root on the NAS out of the auto-pulled clone. To exercise it by hand after a change:

```sh
sudo /bin/sh /mnt/apps/scripts/nas/scripts/pg-dump-backup.sh
```

It prints one `Dumping <host>/<db> (<container>) -> <path>` line per discovered DB and exits
non-zero with an alert mail on any problem.

For a **major-version** upgrade (e.g. 15/16/17 → 18) the image swap alone crash-loops the
container — follow [Postgres major-version upgrade](../setup-operations/postgres-major-upgrade.md),
which uses these dumps as the restore path.

> **Immich note:** restore the `immich` dump into the same `pgvecto`/VectorChord image — the dump
> references the vector extension, which must exist in the target. After a DB restore, also run
> Immich's library/thumbnail jobs as its docs describe.
