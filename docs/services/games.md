# Service: Games (GameVault)

## Overview

GameVault game-library server and its own Postgres. Split out of the old `mediaserver` stack on
2026-08-21 ([STR-1](../architecture-review-2026-08-20.md#str-1--split-the-15-service-mediaserver-stack))
— it is not media at all, and it carries a database, which is reason enough not to share a
rollback with a subtitle fetcher.

### Containers

| Container | Role |
| --- | --- |
| gamevault-backend | Game library server |
| gamevault-db | PostgreSQL 18 for GameVault |

## Stack

- **Stack folder:** `stacks/games/`
- **Compose file:** `stacks/games/docker-compose.yml`
- **Deploy:** Komodo Stack `games` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Service | URL | Port |
| --- | --- | --- |
| GameVault | `https://games.example.com` | 8080 |

LAN-only — not in the VPS SNI allowlist, and Caddy's `lan_only` snippet aborts any other client.

## Volumes / data

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/media` (gamevault) | `/mnt/apps/mediaserver/config/gamevault/images` | Cover images |
| `/var/lib/postgresql` | `/mnt/apps/mediaserver/config/gamevault/db` | Postgres 18 datadir (versioned; data under `db/18/docker`) |
| `/files` (gamevault) | `/mnt/data/mediaserver/data/media/games` | Game files |

> Host paths deliberately stayed under `/mnt/apps/mediaserver/`. That matters here specifically:
> the nightly dump writes to `/mnt/apps/mediaserver/config/gamevault/dumps`, and moving the
> dataset would have moved the dump path too.

## Environment variables

| Variable | Description |
| --- | --- |
| `GAMEVAULT_DB_PW` | GameVault Postgres password |

## Dependencies

- `gamevault-backend` → `gamevault-db` on the stack's own `default` network (`DB_HOST=gamevault-db`).
  Nothing here crosses to another stack.
- `media_net` (external) — joined for consistency with the other split stacks; nothing depends on
  it today.
- `proxy_games` (external) — defined by the `caddy` stack.

## Backup

`gamevault-db` carries the `nas.backup.*` labels that
[`pg-dump-backup.sh`](../../scripts/pg-dump-backup.sh) discovers, so the nightly logical dump
followed the service into this stack automatically — no script edit
([STR-5](../architecture-review-2026-08-20.md#str-5--dump-list-is-hardcoded-not-discovered)).
Dumps land in `/mnt/apps/mediaserver/config/gamevault/dumps`.

## Operations

### Restart / redeploy

Komodo → Stacks → `games` → **Restart** or **Deploy**, or push to `stacks/games/` (the runner deploys it
through Komodo). This no longer bounces
Jellyfin and the *arr suite, which it did as part of `mediaserver`.

### Upgrade

Pinned `tag@sha256:digest`. The Postgres image is on the stateful/blast-radius list in
`renovate.json` (labelled `needs-manual-review`) and on the sweep's `MERGE_SKIP_IMAGES`, so its bumps
are merged by hand; the GameVault image goes through the normal review sweep. GameVault's Postgres migrated
17→18 on 2026-07-02 — see the
[postgres-major-upgrade runbook](../runbooks/setup-operations/postgres-major-upgrade.md).

### Restore from backup

1. Stop the stack.
2. Restore `apps/mediaserver/config/gamevault` from a ZFS snapshot or Hetzner.
3. **Preferred DB path:** load the logical dump — see
   [postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md).
4. Start the stack.

### Common failures

- **Backend won't start / DB connection refused** → `gamevault-db` unhealthy, or `GAMEVAULT_DB_PW`
  missing from the stack env. This stack has its own vault entry now
  (`secrets.enc/portainer-env/games.env.age`), separate from the old `mediaserver` one.
- **Library empty** → `/files` mount, `/mnt/data/mediaserver/data/media/games`.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
