# Runbook: Off-site backup (TrueNAS Cloud Sync → Hetzner)

Important config and data are pushed nightly from the NAS to a **Hetzner Storage Box**
(`u000000.your-storagebox.de`, SFTP) using TrueNAS's built-in **Cloud Sync** feature.

Backups are **snapshot-based**: before each push, TrueNAS takes a temporary ZFS snapshot of
the source dataset and syncs from that snapshot. This guarantees a consistent point-in-time
copy even if files change mid-transfer. All data is **encrypted** before it leaves the NAS.

## Design: one template task, driven per leaf dataset

The snapshot option only works on a dataset that has **no child datasets**. TrueNAS rejects it
on any parent (the API returns `[EINVAL] ... This option is only available for datasets that
have no further nesting`, and the web UI shows the same error).

Because pools like `apps` and `data` are nested several levels deep, a single whole-pool task
cannot use snapshots. Earlier there was one Cloud Sync task **per** leaf dataset — dozens of
them, cluttering the Cloud Sync UI. Now there is a **single template task** (the only
`snapshot: true` task) that the chain script reshapes for each dataset in turn:

- before each dataset it rewrites the template's `path`, `attributes.folder` and `exclude`,
- snapshots that leaf dataset, then pushes it with `rclone` over SFTP,
- mirrors the dataset path into the remote: `/mnt/<pool>/<rel>` → `/backup/<pool>/<rel>`,
- reuses the one set of Hetzner credentials and the encryption key held on the template.

Only `path`/`folder`/`exclude`/`description` are ever touched — the credentials and
`encryption_password`/`encryption_salt` on the template are never read or rewritten, so nothing
depends on the API returning those secrets. The **remote folder layout on Hetzner is unchanged**:
each leaf still lands in its own `/backup/<pool>/<rel>` folder exactly as before.

The whole-pool tasks (`App sync`, `Data Sync`) exist but are **disabled** (they are `snapshot:
false`, so they never collide with the template).

## What is backed up

**Application config** — all leaf datasets under `apps`, e.g. `portainer`, `authentik`,
`immich` (database), `npm`, `kuma`, `mealie`, and every `mediaserver/config/*` service. The
Jellyfin task excludes its regenerable `cache/` directory. (`apps/tailscale` is the one
deliberate exception — see below.)

**Off-NAS hosts** — `apps/a1-matrix` holds the Ampere A1's Synapse dumps and media store, pulled
over the tailnet before this window. Because the chain discovers leaf datasets rather than reading
a list, that dataset was carried offsite with no change to this task:
[a1-matrix-backup.md](a1-matrix-backup.md).

**Komodo** — only `apps/komodo/backups`, Core's dated database dumps (01:00 daily, the
`Backup Core Database` procedure). Its parent `apps/komodo` holds the live MongoDB files, Core's
key pair and the periphery's repo clone, and is skipped because it has a child: the dumps are the
restorable copy ([komodo.md](../../services/komodo.md)). Created 2026-09-15, joined with no change
to the chain.

**User data** — selected leaf datasets under `data`:

- `data/immich` — photo/video library
- `data/paperless` — Document archive
- `data/smb_share/diana`, `data/smb_share/shared`, `data/smb_share/stefan`

## What is intentionally NOT backed up

| Dataset | Reason |
| --- | --- |
| `data/mediaserver` | Bulk media (downloads/library), re-downloadable; too large for off-site |
| `apps/.ix-virt`, `apps/.system/*` | TrueNAS system / VM internals |
| `apps/ix-apps/*` | TrueNAS-managed Docker/catalog data (regenerable) |
| `apps/mediaserver/config/jellyfin/cache` | Regenerable transcode/image cache |
| `apps/tailscale` | Node state/keys — re-created by re-auth with a fresh `TS_AUTHKEY`; local snapshot only |

## Remote folder layout

The Storage Box root is `/backup/`. Because `filename_encryption: false`, folder names stay in
clear and the remote mirrors the dataset paths 1:1 (`/mnt/<pool>/<rel>` → `/backup/<pool>/<rel>`).
Each leaf dataset still gets its own folder — the single template task is pointed at each leaf's
`/backup/<pool>/<rel>` in turn, so the layout below is identical to the old one-task-per-dataset era.

```text
/backup/
├── apps/                              # whole-pool task (DISABLED)
│   ├── a1-matrix/                     # the A1's DB dumps, media store, Kuma state
│   ├── adguard/
│   │   ├── config/
│   │   └── workdir/
│   ├── authentik/                     # Postgres DB + pg_dump
│   ├── beszel/
│   ├── caddy/                         # certificates + ACME account
│   ├── filebrowser/                   # orphaned: the archived app's state
│   ├── files/
│   ├── homarr/
│   ├── immich/                        # Postgres DB + pg_dump
│   ├── kuma/
│   ├── komodo/
│   │   └── backups/                   # Core's dated Mongo dumps (parent not synced)
│   ├── mealie/                        # Postgres DB + pg_dump
│   ├── npm/                           # CrowdSec state (crowdsec/) + archived NPMplus config
│   ├── observability/
│   │   ├── geoip/  grafana/  vector/  victorialogs/  victoriametrics/
│   ├── paperless/                     # Postgres DB + pg_dump
│   ├── portainer/
│   ├── romm/                          # MariaDB DB + mariadb-dump
│   │   ├── assets/  config/  db/  dumps/  redis/  resources/
│   ├── scripts/
│   └── mediaserver/
│       └── config/
│           ├── bazarr/
│           ├── gamevault/             # Postgres DB + pg_dump
│           ├── gluetun/
│           ├── jellyfin/             # excludes cache/
│           ├── prowlarr/
│           ├── qbittorrent/
│           ├── questarr/
│           ├── radarr/
│           ├── sabnzbd/
│           ├── seerr/
│           ├── shelfmark/
│           ├── sonarr/
│           └── unpackerr/
└── data/                              # whole-pool task (DISABLED)
    ├── immich/                        # photo/video library
    ├── paperless/                     # document media
    └── smb_share/
        ├── diana/
        ├── shared/
        └── stefan/
```

`/backup/apps` and `/backup/data` are the whole-pool tasks (`App sync`, `Data Sync`), disabled —
not written.

## Schedule — one sequential chain

The Storage Box caps **concurrent connections**, and each `rclone` task opens several SSH
channels (`transfers: 16`). Staggering each task on its own cron minute overruns that cap:
long-running tasks (jellyfin, immich, authentik) hold their connections open and overlap the
wave of small tasks — combined channels exceed the cap and the box refuses them
(`ssh: unexpected packet in response to channel open`, `connection refused`, `connection lost`).

**Design: never run two datasets at once.** The template task's own cron schedule is
**disabled** (`enabled: false`). A single TrueNAS cron at **03:00** runs
[`scripts/cloudsync-chain.sh`](../../../scripts/cloudsync-chain.sh) straight out of the auto-pulled
clone (`/mnt/apps/scripts/nas/scripts/cloudsync-chain.sh`), which:

1. takes an exclusive lock (the template is a shared, mutated object — a second run would stomp
   its `path`/`folder` mid-sync);
2. **sweeps leaked temp snapshots** — destroys any `@cloud_sync-<taskid>-<timestamp>` snapshot
   older than `SWEEP_DAYS` (2), see [below](#leaked-temp-snapshots);
3. finds the template (the one `snapshot: true` task) and reads its attributes once;
4. builds the dataset list **live from `pool.dataset.query`**, ordered **all `data` leaves first,
   then all `apps` leaves** (see [dataset selection](#which-datasets-are-selected) below);
5. for each leaf: rewrites the template's `path` + `attributes.folder` (+ jellyfin's `/cache/**`
   exclude), runs `midclt call cloudsync.sync <template-id>` (which works regardless of the
   `enabled` flag), and polls `core.get_jobs` until that job reaches a terminal state before the
   next leaf;
6. continues on failure (each dataset is independent), logs to `/var/log/cloudsync-chain.log`,
   and on exit resets the template's description to `Backup chain template (idle)`.

So at most one dataset's SFTP connections exist at any moment, and `apps` start the instant the
last `data` leaf finishes — no fixed hour boundary, no idle gaps. Because the list is derived
live from ZFS, **a newly created leaf dataset joins automatically** — an `apps` leaf needs no
edit at all; a new `data` leaf only needs adding to `DATA_INCLUDE` in the script.

### Which datasets are selected

The script does not sync every leaf blindly — it mirrors the "what is / is NOT backed up" tables
above:

- **`data` pool — whitelist.** Only leaves under `DATA_INCLUDE` (`data/immich`, `data/paperless`,
  `data/smb_share`). The bulk `data/mediaserver` library is never synced.
- **`apps` pool — everything except `APPS_EXCLUDE`** (`apps/.system`, `apps/.ix-virt`,
  `apps/ix-apps`, `apps/tailscale`). New app config leaves are picked up for free.

`DATA_INCLUDE` / `APPS_EXCLUDE` live at the top of the script; keep them in sync with those
tables. Only leaf datasets (no children) qualify — parents are skipped automatically.

> Size does not affect scheduling (serial run, no overlap). The 137G `data/immich` initial
> scan dominates wall-clock on first seed; after that nightly runs only push the small delta.

### Leaked temp snapshots

TrueNAS snapshots the leaf before each push and deletes that snapshot when the transfer ends.
If a run is interrupted the snapshot survives — and **nothing else ever cleans it up**. The
nightly health check found 19 of them on 2026-08-13, pinning ~4.4 GB on the non-redundant `apps`
NVMe: one batch from **2026-03-25** (still there 140 days later, `apps/ix-apps/docker` alone
holding 2.6 GB) and one from an aborted run on **2026-06-30** (`apps/immich` 1.34 GB).

The chain now destroys them itself, before it starts syncing:

- Match is `@cloud_sync-<taskid>-<YYYYMMDDHHMMSS>` — the name carries its own timestamp, so age
  costs no extra property read. `@auto-*` (the retention snapshots) and hand-made `@manual-*`
  snapshots are never touched.
- Older than `SWEEP_DAYS` (2) only. A live run cannot be that old: the script holds an exclusive
  lock and one full pass takes hours, not days.
- Runs **before** the chain, not after, so a run that dies half way still gets its strays
  collected the next night.
- Each destroy is logged (`SWEEP destroyed leaked temp snapshot …`) in
  `/var/log/cloudsync-chain.log`; a failed destroy logs an error and the chain continues.

List what is there by hand:

```sh
sudo zfs list -H -t snapshot -o name,creation,used | grep '@cloud_sync-'
```

## Failure alerts (email)

**The script emails you when a dataset fails** — do not rely on TrueNAS to do it. TrueNAS's
native *Cloud Sync task failed* alert and its cron-output email both send to the **admin
account's** email address, which is **unset**; and even with it set, every failure would be
attributed to the one template task rather than the dataset that actually failed.

So at the end of a run, if any dataset failed, the chain sends one summary email listing **each
failed dataset and its rclone error**, via `mail.send` to the address in *System → General →
Email* (`fromemail`). TrueNAS mail is Outlook **OAuth**, so `mail.send` works as long as an
explicit recipient is passed (the script reads `fromemail`) — no SMTP password is stored.

- **Success → no email** (silent). The other datasets in a run continue even if one fails; the
  email covers whatever failed.
- **Whole-run abort** (no template, middleware down, empty dataset list) → a separate
  `[NAS] Cloud Sync backup ABORTED` email.
- No `fromemail` configured → the failure is logged to `/var/log/cloudsync-chain.log` only.

Test the channel by hand (sends a real email):

```bash
midclt call mail.send '{"subject":"[NAS] mail test","text":"ok","to":["you@example.com"]}'
```

## Database consistency

The database-backed stacks (`authentik`, `immich`, `paperless`, `mealie`, `gamevault`, `romm`) are
backed up here as a **snapshot of the live data directory**. That is crash-consistent and normally
restores fine. For a safer, portable restore path, a nightly logical dump runs first and drops a gzipped
logical dump into each DB's already-backed-up dataset — see
[postgres-dump.md](../backup-restore/postgres-dump.md). Both the data dir and the logical dump then travel offsite
in the same cloud-sync run. RomM's dumps get their own `apps/romm/dumps` dataset, because
`apps/romm` has children and the chain syncs leaf datasets only.

## Encryption

Tasks use rclone Crypt with a shared password + salt. **File contents are encrypted; file and
folder names are kept in clear** (`filename_encryption: false`) so the remote layout stays
browsable. Keep the password and salt safe — without them the remote backup cannot be restored.
They are stored in the TrueNAS config (and the TrueNAS config backup); record them in your
password manager as well. See [TrueNAS Config Backup](../backup-restore/truenas-config-backup.md) for how to export it.

## Managing tasks from the command line

The web UI cannot enable snapshots on the template (nested-dataset error above), so manage it
over SSH with `midclt`. Connect:

```bash
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
```

List all Cloud Sync tasks (id, description, enabled, snapshot). After the collapse there should
be exactly **one** `snapshot: true` task — the template:

```bash
midclt call cloudsync.query '[]' '{"select": ["id","description","enabled","snapshot"]}'
```

Run the **whole chain** now (same script the 03:00 cron runs; logs to
`/var/log/cloudsync-chain.log`):

```bash
sudo /bin/sh /mnt/apps/scripts/nas/scripts/cloudsync-chain.sh
```

> Never run the old loose copy at `/mnt/apps/scripts/cloudsync-chain.sh` — no cron uses it any
> more and it predates the leaked-snapshot sweep ([nas-repo-autopull](../setup-operations/nas-repo-autopull.md) → Gotchas).

Sync **one dataset by hand** — point the template at it, then run it (the chain does exactly
this per leaf):

```bash
midclt call cloudsync.update <template-id> \
  '{"path":"/mnt/data/immich","attributes":{...,"folder":"/backup/data/immich"},"exclude":[]}'
midclt call cloudsync.sync <template-id>
```

The template's schedule stays **disabled** so it never auto-fires outside the chain; `midclt call
cloudsync.sync` runs it regardless of that flag:

```bash
midclt call cloudsync.update <template-id> '{"enabled": false}'
```

The same operations are available over the REST API at
`http://192.168.178.111/api/v2.0/cloudsync` using an API key (web UI → Account → API Keys).

## Adding a new dataset to the backup

**No new task is created any more** — the chain derives its dataset list live from `pool.dataset.query`, so
the amount of work depends on the pool:

- **New `apps` leaf dataset** — nothing to do. Any leaf under `apps` that is not in `APPS_EXCLUDE`
  is picked up on the next 03:00 run automatically, into `/backup/apps/<rel>`. (This is why every
  new service with persistent config just works: stand it up on its own leaf and it is backed up.)
- **New `data` leaf dataset** — the `data` pool is a whitelist. Add its prefix to `DATA_INCLUDE`
  at the top of [`scripts/cloudsync-chain.sh`](../../../scripts/cloudsync-chain.sh) and push
  (`main` auto-pulls to the host within 15 min). Without that edit a new `data` leaf is **not**
  synced — deliberate, so bulk data does not silently start going offsite.
- **New thing to skip** — add its prefix to `APPS_EXCLUDE` (or drop it from `DATA_INCLUDE`).

If you add child datasets **under** an existing backed-up leaf, that former leaf becomes a parent
and is skipped (snapshots need a leaf); its new children become the leaves and are picked up by
the same rules — no task surgery needed.

### One-time migration (collapse the old per-leaf tasks)

If the old design is still live (dozens of `snapshot: true` tasks), collapse them to one:

1. Pick any one existing per-leaf task to keep as the template (it already holds the credentials +
   encryption password/salt). Rename it: `midclt call cloudsync.update <id> '{"description":"Backup chain template (idle)"}'`.
2. Delete every **other** `snapshot: true` task: `midclt call cloudsync.query '[["snapshot","=",true]]' '{"select":["id","description"]}'`
   to list, then `midclt call cloudsync.delete <id>` for each except the template. **Deleting the
   task does not touch the remote `/backup/...` folders** — the Hetzner data is untouched.
3. Confirm exactly one `snapshot: true` task remains, then run
   `sudo /bin/sh /mnt/apps/scripts/nas/scripts/cloudsync-chain.sh` once by hand and watch
   `/var/log/cloudsync-chain.log`.

## Restore

1. Find the task and remote folder for the dataset you want to restore
   (`cloudsync.query`, look at `attributes.folder`).
2. Create a temporary **PULL** Cloud Sync task (or use `rclone` directly with the same Crypt
   password/salt) pointing the Hetzner remote folder at a scratch path such as
   `/mnt/apps/restore-tmp`.
3. Run it, verify the restored files, then move them into place.
4. For service restores, stop the relevant Stack in Komodo first (**Stop**, never **Destroy**), replace the config
   directory, then start the Stack again.

> The encryption password and salt are required to read anything back. Confirm you have them
> before you need them.
>
> **Prove it, don't assume it.** A backup you have never restored is untested. Run the
> [restore drill](restore-drill.md) quarterly — it pulls one real dataset + one `pg_dump` back
> from Hetzner, decrypts them, and verifies the bytes, all in a scratch path without touching
> production. That is what actually catches a wrong crypt salt or a truncated dump.
