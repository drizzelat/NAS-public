# Storage

Disks and ZFS pools. Host compute/chassis (CPU, board, RAM, controllers, cooling) →
[`docs/hardware.md`](hardware.md).

## Physical disks

| Label      | Size  | Type     | Role            |
| ---------- | ----- | -------- | --------------- |
| boot       | 128GB | SATA SSD | TrueNAS OS boot (Patriot P210, `/dev/sda`) |
| nvme0      | 250GB | NVMe SSD | ZFS pool `apps` |
| data-disk1 | 4TB   | HDD      | ZFS pool `data` |
| data-disk2 | 4TB   | HDD      | ZFS pool `data` |

## Pools / arrays

| Pool name | Disks            | RAID level  | Mount point | Size  |
| --------- | ---------------- | ----------- | ----------- | ----- |
| boot-pool | boot SSD         | single disk | (OS root)   | ~114GB|
| apps      | nvme0            | single disk | /mnt/apps   | 250GB |
| data      | data-disk1+disk2 | mirror      | /mnt/data   | ~3.5TB|

> **`apps` has no disk redundancy (single NVMe) — accepted risk.** Protection is layered
> instead: local ZFS snapshots (fast restore) + nightly encrypted Hetzner push (offsite). On
> NVMe failure, restore config from the latest Hetzner backup; worst-case data loss = changes
> since the last nightly push.

## ZFS datasets

User-facing datasets (excludes `boot-pool` internals and TrueNAS-managed datasets:
`apps/.system`, `apps/.ix-virt`, `apps/ix-apps`). Sizes are a snapshot taken 2026-09-11 and drift
over time.

| Dataset                             | Mount point                              | Used   |
| ----------------------------------- | ---------------------------------------- | ------ |
| apps                                | /mnt/apps                                | 62.0G  |
| apps/a1-matrix                      | /mnt/apps/a1-matrix                      | 11.0G  |
| apps/adguard                        | /mnt/apps/adguard                        | 26.8M  |
| apps/adguard/config                 | /mnt/apps/adguard/config                 | 100K   |
| apps/adguard/workdir                | /mnt/apps/adguard/workdir                | 26.6M  |
| apps/authentik                      | /mnt/apps/authentik                      | 1.50G  |
| apps/beszel                         | /mnt/apps/beszel                         | 66.9M  |
| apps/caddy                          | /mnt/apps/caddy                          | 52.3M  |
| apps/conduit                        | /mnt/apps/conduit                        | —      |
| apps/filebrowser *(orphaned)*       | /mnt/apps/filebrowser                    | 112K   |
| apps/files                          | /mnt/apps/files                          | 32.0M  |
| apps/homarr                         | /mnt/apps/homarr                         | 5.18M  |
| apps/immich                         | /mnt/apps/immich                         | 4.21G  |
| apps/kuma                           | /mnt/apps/kuma                           | 123M   |
| apps/mealie                         | /mnt/apps/mealie                         | 26.1M  |
| apps/mediaserver                    | /mnt/apps/mediaserver                    | 17.9G  |
| apps/mediaserver/config             | /mnt/apps/mediaserver/config             | 17.9G  |
| apps/mediaserver/config/bazarr      | /mnt/apps/mediaserver/config/bazarr      | 7.70M  |
| apps/mediaserver/config/gamevault   | /mnt/apps/mediaserver/config/gamevault   | 33.5M  |
| apps/mediaserver/config/gluetun     | /mnt/apps/mediaserver/config/gluetun     | 776K   |
| apps/mediaserver/config/jellyfin    | /mnt/apps/mediaserver/config/jellyfin    | 13.2G  |
| apps/mediaserver/config/prowlarr    | /mnt/apps/mediaserver/config/prowlarr    | 92.8M  |
| apps/mediaserver/config/qbittorrent | /mnt/apps/mediaserver/config/qbittorrent | 18.5M  |
| apps/mediaserver/config/questarr    | /mnt/apps/mediaserver/config/questarr    | 1004K  |
| apps/mediaserver/config/radarr      | /mnt/apps/mediaserver/config/radarr      | 88.2M  |
| apps/mediaserver/config/sabnzbd     | /mnt/apps/mediaserver/config/sabnzbd     | 5.62M  |
| apps/mediaserver/config/seerr       | /mnt/apps/mediaserver/config/seerr       | 6.82M  |
| apps/mediaserver/config/shelfmark   | /mnt/apps/mediaserver/config/shelfmark   | 34.4M  |
| apps/mediaserver/config/sonarr      | /mnt/apps/mediaserver/config/sonarr      | 105M   |
| apps/mediaserver/config/unpackerr   | /mnt/apps/mediaserver/config/unpackerr   | 96K    |
| apps/npm                            | /mnt/apps/npm                            | 91.4M  |
| apps/observability                  | /mnt/apps/observability                  | 385M   |
| apps/observability/geoip            | /mnt/apps/observability/geoip            | 55.1M  |
| apps/observability/grafana          | /mnt/apps/observability/grafana          | 262M   |
| apps/observability/vector           | /mnt/apps/observability/vector           | 1.10M  |
| apps/observability/victorialogs     | /mnt/apps/observability/victorialogs     | 16.2M  |
| apps/observability/victoriametrics  | /mnt/apps/observability/victoriametrics  | 50.4M  |
| apps/paperless                      | /mnt/apps/paperless                      | 121M   |
| apps/portainer *(orphaned)*         | /mnt/apps/portainer                      | 87.1M  |
| apps/romm                           | /mnt/apps/romm                           | 248M   |
| apps/romm/assets                    | /mnt/apps/romm/assets                    | 96K    |
| apps/romm/config                    | /mnt/apps/romm/config                    | 100K   |
| apps/romm/db                        | /mnt/apps/romm/db                        | 19.4M  |
| apps/romm/dumps                     | /mnt/apps/romm/dumps                     | 2.52M  |
| apps/romm/redis                     | /mnt/apps/romm/redis                     | 58.6M  |
| apps/romm/resources                 | /mnt/apps/romm/resources                 | 166M   |
| apps/runner-vm *(zvol)*             | /dev/zvol/apps/runner-vm                 | 1.97G  |
| apps/scripts                        | /mnt/apps/scripts                        | 34.8M  |
| apps/tailscale                      | /mnt/apps/tailscale                      | 1.71M  |
| data                                | /mnt/data                                | 2.28T  |
| data/immich                         | /mnt/data/immich                         | 138G   |
| data/mediaserver                    | /mnt/data/mediaserver                    | 2.02T  |
| data/paperless                      | /mnt/data/paperless                      | 716K   |
| data/romm *(quota 500G)*            | /mnt/data/romm                           | 48.9G  |
| data/romm/bios                      | /mnt/data/romm/bios                      | 112K   |
| data/romm/roms                      | /mnt/data/romm/roms                      | 48.9G  |
| data/smb_share                      | /mnt/data/smb_share                      | 86.6G  |
| data/smb_share/diana                | /mnt/data/smb_share/diana                | 81.3G  |
| data/smb_share/shared               | /mnt/data/smb_share/shared               | 140K   |
| data/smb_share/stefan               | /mnt/data/smb_share/stefan               | 5.22G  |

> `apps/portainer` is **orphaned**: it backs no stack since Portainer's removal on 2026-09-17. Its data
> and the snapshot `pre-removal-2026-09-17` are kept until a separate decision ([archive/portainer.md](archive/portainer.md)).

> `apps/runner-vm` is a **zvol**, not a filesystem: the [runner VM](runbooks/setup-operations/runner-vm.md)'s
> 20 GiB sparse disk, created 2026-09-17. It has no mountpoint and no stack mounts it. The cloud-sync
> chain takes filesystem datasets only, so it is **not backed up offsite**, on purpose: the guest is
> rebuilt from `vm/runner-vm/`. The recursive `apps` snapshot task does include it.

> **Datasets that back no stack bind mount, on purpose:** `apps/a1-matrix` (the A1's nightly
> backup target — [a1-matrix-backup](runbooks/backup-restore/a1-matrix-backup.md)),
> `apps/romm/dumps` (RomM's nightly dump, written from the host; a dataset of its own because the
> cloud sync skips `apps/romm`, which has children — [postgres-dump](runbooks/backup-restore/postgres-dump.md)), `apps/scripts`
> (the on-NAS repo clone and the out-of-band host scripts), and `apps/filebrowser`, which is
> **orphaned** — the archived filebrowser's state, left on disk deliberately at the 2026-09-09
> cutover ([filebrowser-to-quantum](runbooks/setup-operations/filebrowser-to-quantum.md)).
> `apps/npm` is not orphaned: the `caddy` stack's `crowdsec` mounts its `crowdsec/` subtree.
>
> `/mnt/apps/nas-health` is a plain directory in the `apps` root dataset, not a leaf dataset, so the
> cloud-sync chain does not carry it offsite (it syncs leaves only). It is disposable: it holds only
> the forced-command `authorized_keys`, re-created from the vault
> ([nas-health-check](runbooks/setup-operations/nas-health-check.md)).

## Shares / bind mounts used by stacks

AI agents: when adding a new stack that uses a host volume, add a row here.

| Path on host                              | Used by stack | Purpose                          |
| ----------------------------------------- | ------------- | -------------------------------- |
| `/mnt/apps/adguard/config`                | adguard       | AdGuard config files             |
| `/mnt/apps/adguard/workdir`               | adguard       | AdGuard working data / stats     |
| `/mnt/apps/authentik/db`                  | authentik     | Postgres database                |
| `/mnt/apps/authentik/media`               | authentik     | Uploaded media/icons             |
| `/mnt/apps/authentik/custom-templates`    | authentik     | Custom flow templates            |
| `/mnt/apps/authentik/certs`               | authentik     | TLS certificates                 |
| `/mnt/apps/komodo/repos/nas/stacks/authentik/blueprints` | authentik | Blueprints, read-only from Komodo's clone |
| `/mnt/apps/beszel/hub_data`               | beszel        | Beszel hub database              |
| `/mnt/apps/caddy/data`                    | caddy         | Certificates + ACME account      |
| `/mnt/apps/caddy/config`                  | caddy         | Caddy's autosaved JSON config    |
| `/mnt/apps/caddy/logs`                    | caddy         | Access log, read by CrowdSec + Vector |
| `/mnt/apps/komodo/repos/nas/stacks/caddy` | caddy         | Edge policy, read-only from Komodo's clone |
| `/mnt/apps/conduit`                       | conduit       | Station key (broker reputation) + Psiphon tunnel-core state |
| `/mnt/apps/komodo`                        | nas-periphery | Periphery root, identical inside and out (F4): repo clones, stack dirs, its key pair |
| `/mnt/apps/komodo/mongo/db`               | komodo        | Komodo Core's MongoDB data |
| `/mnt/apps/komodo/mongo/configdb`         | komodo        | MongoDB config data |
| `/mnt/apps/komodo/keys`                   | komodo        | Core's key pair, trusted by every periphery |
| `/mnt/apps/komodo/backups`                | komodo        | Core's dated database backups |
| `/mnt/apps/observability/geoip`           | observability | GeoLite2 mmdb files — geoipupdate writes, vector reads |
| `/mnt/apps/observability/grafana`         | observability | Grafana state (users, prefs, un-exported dashboards) |
| `/mnt/apps/observability/vector`          | observability | Vector read checkpoints                          |
| `/mnt/apps/observability/victorialogs`    | observability | Log store (90d)                                  |
| `/mnt/apps/observability/victoriametrics` | observability | Metrics store (1y)                               |
| `/mnt/apps/komodo/repos/nas/stacks/observability/vector` | observability | Vector pipeline, read-only from Komodo's clone |
| `/mnt/apps/komodo/repos/nas/stacks/observability/victoriametrics` | observability | Scrape config, read-only from Komodo's clone |
| `/mnt/apps/komodo/repos/nas/stacks/observability/grafana/provisioning` | observability | Grafana datasources + dashboard provider, read-only from Komodo's clone |
| `/mnt/apps/komodo/repos/nas/stacks/observability/grafana/dashboards` | observability | Dashboard JSON, read-only from Komodo's clone |
| `/mnt/apps/files`                         | files         | Quantum SQLite DB + preview cache |
| `/mnt/apps/komodo/repos/nas/stacks/files` | files         | `config.yaml`, read-only from Komodo's clone |
| `/mnt/data/smb_share`                     | files         | Files served in the browser UI   |
| `/mnt/apps/homarr/appdata`                | homarr        | Whole state (SQLite DB + configs); v1 single-dir layout |
| `/mnt/apps/immich`                        | immich        | Postgres 18 + VectorChord database |
| `/mnt/data/immich`                        | immich        | Photo/video library              |
| `/mnt/apps/kuma`                          | kuma          | Uptime Kuma database & config    |
| `/mnt/apps/mediaserver/config/gluetun`    | downloads     | Gluetun VPN state                |
| `/mnt/apps/mediaserver/config/qbittorrent`| downloads     | qBittorrent config               |
| `/mnt/apps/mediaserver/config/sabnzbd`    | downloads     | SABnzbd config                   |
| `/mnt/apps/mediaserver/config/prowlarr`   | arr           | Prowlarr config                  |
| `/mnt/apps/mediaserver/config/radarr`     | arr           | Radarr config                    |
| `/mnt/apps/mediaserver/config/sonarr`     | arr           | Sonarr config                    |
| `/mnt/apps/mediaserver/config/bazarr`     | arr           | Bazarr config                    |
| `/mnt/apps/mediaserver/config/jellyfin`   | jellyfin      | Jellyfin config                  |
| `/mnt/apps/mediaserver/config/seerr`      | jellyfin      | Seerr config                     |
| `/mnt/apps/mediaserver/config/shelfmark`  | books         | Shelfmark config                 |
| `/mnt/apps/mediaserver/config/gamevault`  | games         | GameVault images + Postgres DB   |
| `/mnt/apps/mediaserver/config/unpackerr`  | arr           | Unpackerr config                 |
| `/mnt/apps/mediaserver/config/questarr`   | arr           | Questarr SQLite database         |
| `/mnt/data/mediaserver/data`              | arr, downloads| Shared for hardlinks — see arr.md|
| `/mnt/data/mediaserver/data/media`        | jellyfin, arr (bazarr) | Media library           |
| `/mnt/data/mediaserver/data/media/books`  | books         | Book library                     |
| `/mnt/data/mediaserver/data/media/games`  | games         | Game files                       |
| `/mnt/data/romm/roms`                     | downloads     | qBittorrent `/roms` — ROM grabs  |
| `/mnt/apps/npm/npm/data/nginx/logs`       | caddy         | NPMplus's static logs, mounted `ro` by `crowdsec` so an NPMplus rollback keeps its acquisition |
| `/mnt/apps/npm/crowdsec/data`             | caddy         | CrowdSec database                |
| `/mnt/apps/npm/crowdsec/config`           | caddy         | CrowdSec configuration           |
| `/mnt/apps/mealie/data`                   | mealie        | Mealie app data (recipes, images)|
| `/mnt/apps/mealie/db`                     | mealie        | Postgres database                |
| `/mnt/apps/paperless/data`                | paperless     | Paperless internal data          |
| `/mnt/apps/paperless/db`                  | paperless     | Postgres database                |
| `/mnt/apps/paperless/redis`               | paperless     | Redis broker data                |
| `/mnt/data/paperless/media`               | paperless     | Stored documents/PDFs            |
| `/mnt/data/paperless/export`              | paperless     | Export directory                 |
| `/mnt/data/paperless/consume`             | paperless     | Drop folder for auto-ingestion   |
| `/mnt/apps/romm/db`                       | romm          | MariaDB database                 |
| `/mnt/apps/romm/config`                   | romm          | RomM config.yml (optional)       |
| `/mnt/apps/romm/resources`                | romm          | Fetched box art / metadata       |
| `/mnt/apps/romm/assets`                   | romm          | **User saves + save-states**     |
| `/mnt/apps/romm/redis`                    | romm          | Bundled Redis task cache         |
| `/mnt/data/romm/roms`                     | romm          | ROM/ISO library (also SMB `roms`)|
| `/mnt/data/romm/bios`                     | romm          | BIOS/system files (PSX etc.)     |
| `/mnt/data`                               | beszel        | Data pool (read-only view; beszel-agent reads usage only) |
| `/mnt/apps/tailscale`                     | tailscale     | Tailscale node state / keys      |

## Disk health (scrub + SMART)

Configured in TrueNAS → Data Protection. Catches silent corruption / failing disks early —
matters most for the `data` mirror (self-heals on scrub) and the single-disk `apps` pool.

| Task         | Target    | Schedule                          |
| ------------ | --------- | --------------------------------- |
| ZFS scrub    | `apps`    | weekly — Tuesday 00:00            |
| ZFS scrub    | `data`    | weekly — Monday 00:00             |
| SMART SHORT  | all SATA disks | daily 02:00 (except Saturday) |
| SMART LONG   | all SATA disks | weekly — Saturday 02:00      |
| SMART SHORT / LONG | `nvme0n1` | same cadence at 02:05, from a cron script — the UI tasks skip NVMe ([scheduled-tasks.md](scheduled-tasks.md)) |

## Local ZFS snapshots

First line of defence (fast, local restore vs accidental delete / bad app write). Managed in
TrueNAS → Data Protection → Periodic Snapshot Tasks. Distinct from the offsite Hetzner backup
below.

| Dataset          | Recursive | Frequency             | Retention |
| ---------------- | --------- | --------------------- | --------- |
| `apps`           | yes       | every 4h (00,04,…,20) | 3 days    |
| `data/smb_share` | yes       | daily 01:00           | 14 days   |
| `data/immich`    | no        | daily 01:00           | 14 days   |
| `data/paperless` | no        | daily 01:00           | 14 days   |

Naming schema `auto-%Y-%m-%d_%H-%M`. `data/mediaserver` (bulk media) and `data/romm` (bulk ROMs —
replaceable, and quota-capped at 500 GB) are intentionally **not** snapshotted. RomM's precious
state (saves/save-states in `apps/romm/assets`, plus its DB) lives on `apps`, which **is**
snapshotted recursively. Restore: `zfs rollback` or browse `.zfs/snapshot/<name>/` and copy files
out.

## Backup (offsite)

Important config and selected data are pushed nightly to a **Hetzner Storage Box** (SFTP) via
TrueNAS **Cloud Sync** — one snapshot-based, encrypted template task re-pointed at each leaf
dataset in turn. See [`docs/runbooks/backup-restore/backup.md`](runbooks/backup-restore/backup.md)
for what is included/excluded, the schedule, and restore steps.
