# Runbook: Backing up the A1

## Why

The Ampere A1 (`a1-matrix`) is the one host in the estate that is deliberately **not** the NAS —
Matrix keeps working while the NAS reboots or resilvers. The cost of that independence is that
none of the NAS's snapshot, replication or cloud-sync machinery reaches it. Until 2026-08-21 the
Synapse database, the media store and the WhatsApp bridge's session state existed in exactly one
copy, on one Oracle instance
([GAP-2](../../architecture-review-2026-08-20.md#gap-2--a1-matrix-host-has-no-backup)).

The fix pulls that data from the NAS into `apps/a1-matrix`, which the existing 03:00 chain then carries
offsite with no extra task — [`cloudsync-chain.sh`](../../../scripts/cloudsync-chain.sh) discovers
leaf datasets under `apps`, so a new dataset is backed up by construction.

## What is covered

| Thing | Size | How | Lands in |
| --- | --- | --- | --- |
| `synapse` Postgres DB | ~1.3 GB | `pg_dump` via [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) | `/mnt/apps/a1-matrix/dumps` |
| `mautrix_whatsapp` Postgres DB | ~78 MB | same | `/mnt/apps/a1-matrix/dumps` |
| Synapse media store | ~9.3 GB | `rsync` via [`a1-file-backup.sh`](../../../scripts/a1-file-backup.sh) | `/mnt/apps/a1-matrix/media_store` |
| Uptime Kuma state (`/opt/kuma/data`) | ~3.5 MB | same script | `/mnt/apps/a1-matrix/kuma` |
| Signing key | 4 KB | already in the age vault at `secrets.enc/ssh/example.com.signing.key.age` | — |

The A1 also hosts the estate's **external watchdog** since
[STR-2](../../architecture-review-2026-08-20.md#str-2--the-external-watchdog-is-inside-what-it-watches).
Its SQLite DB used to sit in a named volume with no backup at all; it is now a host bind and rides
along here. Service doc: [a1-vps-kuma.md](../../services/a1-vps-kuma.md).

**The bridge's session state is in Postgres, not on disk.** `mautrix_whatsapp` holds the WhatsApp
pairing, so the DB dump is what saves you from re-pairing every bridge by QR.
`/opt/matrix/bridges/whatsapp/` is ~593 MB of **logs** and is deliberately not synced.

**Not covered here: configuration, because it is in git.** `homeserver.yaml`, the log config, both
appservice registrations, the Caddyfile and Element's `config.json` are inline `configs:` in
[`stacks/a1-vps-matrix/docker-compose.yml`](../../../stacks/a1-vps-matrix/docker-compose.yml), with
their secrets in the vault ([GAP-2](../../architecture-review-2026-08-20.md#gap-2--a1-matrix-host-has-no-backup)).
The exception is the WhatsApp bridge's own `config.yaml` + `registration.yaml` under
`/opt/matrix/bridges/whatsapp/`: host-side (the bridge rewrites them on upgrade) and not synced.
On a rebuild, regenerate them per [matrix-deploy](../setup-operations/matrix-deploy.md) Phase 6 with
the tokens from the vault.

## How the NAS reaches the A1

Both jobs run as **root on the NAS** and pull over the tailnet (`100.64.0.13`, port `2222`).
Three dedicated keys, each locked to exactly one forced command on the A1 — none can open a shell:

| Key (on NAS) | `authorized_keys` restriction (on A1) | Used by |
| --- | --- | --- |
| `/root/.ssh/a1_backup_docker` | `restrict,command="sudo /usr/bin/docker system dial-stdio"` | `docker -H ssh://a1-docker` |
| `/root/.ssh/a1_backup_files` | `restrict,command="/usr/bin/rrsync -ro /opt/matrix/synapse/media_store"` | `rsync a1-files:/` |
| `/root/.ssh/a1_backup_kuma` | `restrict,command="/usr/bin/rrsync -ro /opt/kuma/data"` | `rsync a1-kuma:/` |

One key per scope on purpose: an `authorized_keys` entry carries exactly one forced command, so a
new path to back up means a new key rather than widening an existing one. **The SSH alias is the
access scope** — that is why `a1-file-backup.sh` names aliases and not paths.

`restrict` disables pty, port-forwarding and agent-forwarding. `rrsync -ro` confines each of the two
files keys to a read-only view of its directory and rejects `..` escapes.

> **Honest limit:** `docker system dial-stdio` is the full Docker API, which is root-equivalent on
> that host. The forced command stops the key being used as a general shell; it is not a privilege
> boundary. Treat `a1_backup_docker` as a host-root credential.

`/root/.ssh/config` on the NAS defines the three aliases:

```
Host a1-docker
    HostName 100.64.0.13
    Port 2222
    User ubuntu
    IdentityFile /root/.ssh/a1_backup_docker
    IdentitiesOnly yes

Host a1-files
    HostName 100.64.0.13
    Port 2222
    User ubuntu
    IdentityFile /root/.ssh/a1_backup_files
    IdentitiesOnly yes

Host a1-kuma
    HostName 100.64.0.13
    Port 2222
    User ubuntu
    IdentityFile /root/.ssh/a1_backup_kuma
    IdentitiesOnly yes
```

The A1's host key is pinned in `/root/.ssh/known_hosts` as `[100.64.0.13]:2222`.

## Schedule

| Time | Job |
| --- | --- |
| 02:00 | `a1-file-backup.sh` — media store + Kuma state rsync |
| 02:30 | `pg-dump-backup.sh` — all DBs including the A1's two |
| 03:00 | `cloudsync-chain.sh` — picks up `apps/a1-matrix` offsite |

Both run from the auto-pulled on-host clone, so editing the scripts and pushing is the whole
deployment step. Local ZFS history comes from the recursive `apps` snapshot task (4-hourly, 3-day
retention), which covers the new dataset automatically.

The file sync uses `--delete`, so each mirror is true: a file deleted on the A1 disappears from the
mirror on the next run. Deletion history is the snapshot task and the offsite copy, not an
ever-growing directory. It is single-instance (`flock` on `/var/run/a1-file-backup.lock`) — a cold
first sync takes about an hour, and a lock still held at the next nightly run alerts rather than
being skipped quietly.

## Rebuilding the A1 from these backups

1. Provision the host and block volume per [a1-provision](../setup-operations/a1-provision.md), and
   restore the signing key from the vault — **without it the federation identity is gone**:

   ```sh
   ./scripts/secrets.sh decrypt   # writes secrets/ssh/example.com.signing.key
   scp -P 2222 -i secrets/ssh/ssh-a1-key.key secrets/ssh/example.com.signing.key \
     ubuntu@198.51.100.20:/tmp/ && \
     ssh -p 2222 -i secrets/ssh/ssh-a1-key.key ubuntu@198.51.100.20 \
       'sudo install -o systemd-resolve -g systemd-resolve -m 600 /tmp/example.com.signing.key /opt/matrix/synapse/'
   ```

2. Recreate the bridge's host-side `config.yaml` + `registration.yaml`, put the stack's env back
   (`scripts/secrets.sh push a1-vps-matrix` — every other config is in the compose file), and let
   the stack deploy so Postgres initialises an empty cluster.
   **The `synapse` DB must be created with `LC_COLLATE=C`** — the compose `POSTGRES_INITDB_ARGS`
   does that on first boot only.
3. Stop `matrix-synapse` and `matrix-mautrix-whatsapp` so nothing writes, then load both dumps:

   ```sh
   for db in synapse mautrix_whatsapp; do
     gunzip -c /mnt/apps/a1-matrix/dumps/${db}_<stamp>.sql.gz \
       | docker -H ssh://a1-docker exec -i matrix-postgres psql -q -v ON_ERROR_STOP=1 -U synapse -d "$db"
   done
   ```

   `mautrix_whatsapp` will not exist on a fresh cluster — create it first:
   `docker -H ssh://a1-docker exec matrix-postgres createdb -U synapse mautrix_whatsapp`.
4. Push the media store back. **Every backup key is read-only** (`rrsync -ro`), so restores use the
   admin key `secrets/ssh/ssh-a1-key.key`:

   ```sh
   rsync -a -e "ssh -i secrets/ssh/ssh-a1-key.key -p 2222" \
     /mnt/apps/a1-matrix/media_store/ ubuntu@198.51.100.20:/tmp/media_store/
   # then, on the A1:
   sudo rsync -a /tmp/media_store/ /opt/matrix/synapse/media_store/
   sudo chown -R systemd-resolve:systemd-resolve /opt/matrix/synapse/media_store
   ```

   Same shape for `/mnt/apps/a1-matrix/kuma/` → `/opt/kuma/data` (owned `root:root`).
5. Start the stack and confirm: Synapse logs "Synapse now listening on TCP port 8008", Element
   loads history, and the WhatsApp bridge reconnects **without** asking for a QR code (that is the
   proof the bridge DB restored correctly).

## Verifying it by hand

```sh
sudo /bin/sh /mnt/apps/scripts/nas/scripts/a1-file-backup.sh
sudo /bin/sh /mnt/apps/scripts/nas/scripts/pg-dump-backup.sh
ls -lh /mnt/apps/a1-matrix/dumps/ /mnt/apps/a1-matrix/kuma/
```

Both scripts exit non-zero and send an alert mail on any problem, and both support an optional
Uptime-Kuma push heartbeat (`/root/.config/a1-file-backup-kuma-push.url`,
`/root/.config/pg-dump-kuma-push.url`) so *not running at all* is also detectable.

## Common failures

- **`ssh: connect to host 100.64.0.13 port 2222: Network is unreachable`** — the tailnet is
  down on one end. `tailscale status` on both hosts.
- **`rrsync error: SSH_ORIGINAL_COMMAND does not run rsync`** — something invoked a files key
  with a non-rsync command. Expected, and proof the restriction holds.
- **`another sync still holds /var/run/a1-file-backup.lock`** — the previous run never finished.
  Check for a stuck `rsync` on the NAS before clearing it.
- **`Host key verification failed`** — the A1 was rebuilt and its host key changed. Re-pin:
  `ssh-keygen -R '[100.64.0.13]:2222'` then `ssh-keyscan -p 2222 -t ed25519 100.64.0.13 >> /root/.ssh/known_hosts`.
- **Dump reports `SKIP a1/synapse: container 'matrix-postgres' is not running`** — the stack is
  down on the A1, not a backup fault.

## Last updated

2026-09-11
