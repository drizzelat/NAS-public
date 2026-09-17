# Service: RomM

## Overview

Self-hosted **retro game library**. RomM catalogues a ROM collection, pulls box art/metadata, and
plays the retro tier **in the browser** via its bundled EmulatorJS player — nothing to install on
the client. It is a *library manager, not a downloader*: it never fetches ROMs itself.

The NAS is an **Intel N100, iGPU only** — it **never emulates 3D consoles**. Emulation compute
lives on the client:

| Console tier | Runs where |
| --- | --- |
| NES/SNES/N64/GB/GBA/GBC/DS/Genesis/PSX | EmulatorJS **in the browser** (client CPU/WASM) |
| GameCube / Wii / Switch | **native emulator on the client**, reading ROMs over the `roms` SMB share |

Bring-up + ROM acquisition: [romm-emulation runbook](../runbooks/setup-operations/romm-emulation.md).

## Stack

- **Stack folder:** `stacks/romm/`
- **Compose file:** `stacks/romm/docker-compose.yml`
- **Deploy:** Komodo Stack `romm` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

Two containers: `romm` (app + bundled Redis + nginx) and `romm-db` (**MariaDB** — RomM does not
run on plain MySQL).

## Access

| | |
|---|---|
| URL | <https://romm.example.com> |
| Port | `8080` internal only — no host port; Caddy reaches it over `proxy_romm` |
| Auth | RomM native login. First user to hit the URL **claims admin** (setup wizard) |
| Exposure | **LAN + Tailscale only** (Caddy `lan_only` snippet). Not in the VPS SNI allowlist, so not public |

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/var/lib/mysql` | `/mnt/apps/romm/db` | MariaDB data |
| `/romm/config` | `/mnt/apps/romm/config` | optional `config.yml` |
| `/romm/resources` | `/mnt/apps/romm/resources` | fetched art/metadata |
| `/romm/assets` | `/mnt/apps/romm/assets` | **user saves + save-states — precious** |
| `/redis-data` | `/mnt/apps/romm/redis` | bundled Redis task cache |
| `/romm/library/roms` | `/mnt/data/romm/roms` | **ROM/ISO library (bulk)** — also the `roms` SMB share |
| `/romm/library/bios` | `/mnt/data/romm/bios` | BIOS/system files (PSX etc.) |

`data/romm` carries a **500 GB ZFS quota** (covers `roms` + `bios`) so the library can't starve
the other `data` tenants. Raise with `zfs set quota=<n>G data/romm`.

## Environment variables

Set via the encrypted vault (`secrets.enc/portainer-env/romm.env.age`); `scripts/secrets.sh push romm` writes the Komodo Variables `ROMM__<KEY>` and deploys — see
[secret-sync](../runbooks/setup-operations/secret-sync.md). Values are **not** in this repo in
the clear.

| Variable | Description |
|---|---|
| `ROMM_AUTH_SECRET_KEY` | Session signing key (`openssl rand -hex 32`) |
| `ROMM_DB_PW` | MariaDB app-user password (`DB_PASSWD` + `MARIADB_PASSWORD`) |
| `ROMM_DB_ROOT_PW` | MariaDB root password (`MARIADB_ROOT_PASSWORD`) |

**No metadata API key is needed.** The stack uses **Hasheous** (`HASHEOUS_API_ENABLED=true`),
which matches ROMs by file hash and requires no account. IGDB/ScreenScraper/SteamGridDB are
optional add-ons.

## Dependencies

- `romm-db` (MariaDB) — `romm` waits on its healthcheck.
- `proxy_romm` network — **defined by the `caddy` stack**, consumed here as `external: true`. It
  must exist before RomM starts.
- Nightly logical DB dump — `romm-db` carries the `nas.backup.*` labels that
  [`scripts/pg-dump-backup.sh`](../../scripts/pg-dump-backup.sh) discovers (engine `mariadb`). The
  dumps land in `/mnt/apps/romm/dumps`, a dataset of its own so the cloud sync carries them offsite.

## Notes

- **Runs as uid/gid 1000, no `PUID`/`PGID`.** The image hard-codes user `romm` (1000) and its
  nginx workers drop to it. Library/asset datasets are owned `1000:1000`, `chmod 2775` (setgid),
  with POSIX ACLs for uid `950` (qBittorrent) and `3002` (the `stefan` SMB user).
- **Folder layout is RomM "Structure A"** — `roms/{platform}` and `bios/{platform}` as
  **siblings**. `bios/` must **not** live inside `roms/`, or it is read as a platform slug.
  Platform folder names must match RomM's supported-platform slugs — **GameCube is `ngc`, not
  `gc`**.
- **COOP/COEP is RomM's job, not the proxy's.** EmulatorJS needs `SharedArrayBuffer`, which needs a
  cross-origin-isolated page. RomM's internal nginx sets the headers **only on the player routes**
  (`/rom/*/ejs`, `/console/rom/<id>/play`) and nowhere else — deliberately, since `require-corp`
  everywhere would block the cross-origin box art. **Never add COOP/COEP with a `header` directive
  in the Caddyfile**: it would duplicate them on the player route (itself an isolation failure) and
  isolate every other page. Caddy only passes them through.
- **Redis is bundled** in the RomM image (the `/redis-data` mount) — no separate Valkey container.
  This is **version-specific**: if a future release externalizes Redis, background tasks
  (scan/metadata) silently queue forever and you must add a `valkey` container + `REDIS_HOST`.
  Check the release notes on every major upgrade.
- **MariaDB memory limit is 1G, not 512M.** A metadata scan plus InnoDB buffer can push it past
  512M, and a Docker hard limit is an **OOM-kill mid-scan**, not back-pressure.
- **DB password rotation is a trap.** `MARIADB_USER`/`MARIADB_PASSWORD` apply **only on first
  init** (empty datadir). Rotating `ROMM_DB_PW` via secret-sync updates the env in both containers
  but **not** the existing MariaDB user — RomM then fails to authenticate and it looks like "wrong
  creds". Rotate properly: `ALTER USER 'romm'@'%' IDENTIFIED BY '<new>';` inside `romm-db`, or wipe
  `apps/romm/db` to force a clean re-init.
- **The inotify rescan is not the primary path.** `ENABLE_RESCAN_ON_FILESYSTEM_CHANGE` can fire
  mid-copy on a bulk import (indexing a half-written ISO) or drop events under a flood. After any
  bulk import, run a **manual Scan**; `ENABLE_SCHEDULED_RESCAN` is the backstop.

## Operations

> Restart/redeploy go through **Komodo** (Stack `romm`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

Komodo → Stacks → `romm` → **Deploy** (or **Restart**). Or push to `stacks/romm/` →
[`deploy-stacks`](../../.github/workflows/deploy-stacks.yml) deploys it through Komodo.

### Upgrade

Renovate opens the PRs. `rommapp/romm` goes through the review sweep — read RomM's release notes
for DB-migration warnings. `mariadb` is on the sweep's `MERGE_SKIP_IMAGES`, so its bumps are merged
by hand. Rollback = revert the commit + redeploy (for the app; see below for the database).

- **MariaDB stays on the 12.3 LTS line.** `renovate.json` caps `mariadb` to `12.3`, so Renovate
  offers only its digests and patches; rolling releases (12.4+, 13.x) never open a PR. Moving to the
  next LTS is a hand-edit. It was 11.4 LTS before 2026-07-16. A major is a **one-way datadir
  upgrade with no downgrade path** — reverting the pin does not make the datadir readable by the
  old major again. Take a fresh logical dump before the next major and restore from it if the
  upgrade goes wrong.
- **Watch for Redis externalization** (see Notes).

### Restore from backup

Stop the stack → restore `apps/romm/*` (**`assets` = saves, `db`, `config`**) from a ZFS snapshot
or Hetzner → start. ROMs (`data/romm/roms`) are **replaceable** — re-copy if lost, don't burn
backup space on them.

If the snapshotted datadir won't come up cleanly (a ZFS snapshot of a live DB is only
crash-consistent), fall back to the **logical dump**: reload
`/mnt/apps/romm/dumps/romm_<stamp>.sql.gz` per the
[DB dump runbook](../runbooks/backup-restore/postgres-dump.md).

> **`apps/romm/dumps` must stay a dataset.** The cloud-sync chain syncs leaf datasets only and
> skips `apps/romm`, which has children. Until 2026-09-11 the dumps were a plain directory there and
> never went offsite.

### Common failures

| Symptom | Cause → fix |
|---|---|
| RomM won't start, DB errors | MariaDB unhealthy or creds mismatch. **MySQL image will not work — must be MariaDB.** |
| Auth fails *after a secret rotation* | Rotated `ROMM_DB_PW` never reached the DB — see the rotation trap in Notes. |
| `romm-db` restarts mid-scan | OOM-killed at the memory limit. Raise `1G` or cap `innodb_buffer_pool_size`. |
| Games not detected on scan | Wrong platform slug (**`ngc`, not `gc`**), or `bios/` nested inside `roms/`. Also: bulk imports need a manual Scan. |
| No box art | Hasheous matches by **file hash** — a bad dump or re-zipped ROM won't match. Use RomM's manual match, or add IGDB. |
| Browser player hangs on `SharedArrayBuffer` | Page isn't cross-origin-isolated. Check HTTPS, and that Caddy is neither **stripping nor duplicating** COOP/COEP (see Notes). |
| Scan/metadata tasks queue but never run | Redis unreachable — after an upgrade that externalized it, add `valkey` + `REDIS_HOST`. |
| Reachable on LAN, not over Tailscale | `100.64.0.0/10` missing from Caddy's `@lan` matcher, or the tailscale stack lost `--snat-subnet-routes=false` ([tailscale.md](tailscale.md)). |
| Permission denied on library | Dataset not owned `1000:1000` / ACLs missing (see Notes). |

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
