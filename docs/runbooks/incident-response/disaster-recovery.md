# Runbook: Bare-metal disaster recovery

Rebuild the NAS after losing the boot drive, a pool, or the whole box. This is the
**orchestrating checklist** — it sequences the focused runbooks rather than repeating
them. Read the linked runbook before executing each phase.

> **Two things restore the system, stored in two places on purpose:**
> the **emailed TrueNAS config** gets back the *configuration* (datasets, tasks, network,
> services); **Bitwarden** gets back the *keys* (the `pwenc_secret` seed + the Cloud Sync
> crypt password/salt + the Hetzner login). You need **both**. See
> [truenas-config-backup.md](../backup-restore/truenas-config-backup.md).

## Pick your scenario

| Lost | Pools intact? | Go to |
| --- | --- | --- |
| Boot/OS drive only | Yes (`apps` + `data` survive) | [Scenario A](#scenario-a--boot-drive-died-pools-intact) |
| A disk in a pool | Pool degraded, not lost | [disk-failure-replacement.md](../incident-response/disk-failure-replacement.md) |
| `apps` NVMe (single disk, no redundancy) | `data` survives | [Scenario B](#scenario-b--apps-nvme-lost-data-intact) |
| Whole box / both pools | No | [Scenario C](#scenario-c--whole-box-lost-full-offsite-rebuild) |
| The Ampere A1 (Matrix, external Kuma, Tor bridges, NTP server) | NAS unaffected | [a1-matrix-backup.md](../backup-restore/a1-matrix-backup.md) → Rebuilding the A1 |

## Before you start — confirm you hold the keys

From **Bitwarden** (a restore stalls here without them — see
[truenas-config-backup.md](../backup-restore/truenas-config-backup.md) → "What must live in Bitwarden"):

- [ ] `pwenc_secret` (base64 seed)
- [ ] Cloud Sync rclone **crypt password + salt**
- [ ] **Hetzner Storage Box** SFTP host/user/password (`u000000.your-storagebox.de`)
- [ ] **TrueNAS admin** password
- [ ] Latest **`freenas-v1.db`** config tarball (from the daily 02:15 email)
- [ ] **age vault passphrase** — `scripts/secrets.sh unlock` needs it to decrypt `secrets.enc/`,
      i.e. every stack's env and the host SSH keys ([secret-sync.md](../setup-operations/secret-sync.md)).
      Without it the stacks come back with no secrets.

## Scenario A — boot drive died, pools intact

Most common, fastest. The data is fine; you're only rebuilding the OS + config.

1. Reinstall **TrueNAS SCALE** on a new boot device; log in with the admin password (Bitwarden).
2. **System → General → Manage Configuration → Upload Config**; upload the latest
   `freenas-v1.db` tarball from email.
3. **Re-apply the seed** — the email omits `pwenc_secret`, so restore it from Bitwarden
   first (recreate `/data/pwenc_secret` from the stored base64, or rebuild the tarball as
   `freenas-v1.db` + `pwenc_secret` and upload that). Without the seed, stored secrets
   (Cloud Sync creds, certs, SMTP) come back blank. Full steps: [truenas-config-backup.md](../backup-restore/truenas-config-backup.md) → Disaster recovery (A).
4. **Import** the existing `apps` and `data` pools (Storage → Import Pool).
5. Services resume from their on-disk config. Run the
   [host-reboot-power-loss.md](../incident-response/host-reboot-power-loss.md) **Verify after every boot**
   checklist.

## Scenario B — `apps` NVMe lost, `data` intact

The `apps` pool is a **single NVMe with no redundancy** (accepted risk — see
[storage.md](../../storage.md)). If that disk dies, all service config/databases are gone but
bulk user data on the mirrored `data` pool survives. Worst-case loss = changes since the
last nightly Hetzner push.

1. Replace the NVMe; recreate the `apps` pool and its datasets (the uploaded config defines
   the layout — restore config as in Scenario A if the boot drive is also affected).
2. **Restore `apps` data from the latest backup:**
   - **Config dirs** (every `apps/<service>` leaf) — PULL from Hetzner with the crypt
     password/salt, per [backup.md](../backup-restore/backup.md) → Restore.
   - **Databases** (Postgres: authentik, immich, paperless, mealie, gamevault; MariaDB: romm) —
     restore from the **logical dumps** that rode offsite inside each DB's dataset; load per
     [postgres-dump.md](../backup-restore/postgres-dump.md). Prefer the dump over the raw data dir.
3. Redeploy the stacks. Komodo's state is on `apps/komodo` — restore it too, and every Stack comes
   back as it was. Without it, bootstrap Core per [komodo.md](../../services/komodo.md) → Bootstrap,
   execute the ResourceSync, run `scripts/secrets.sh komodo-vars --all`, then deploy
   ([deploy-stacks.md](../setup-operations/deploy-stacks.md)).
4. Verify per [host-reboot-power-loss.md](../incident-response/host-reboot-power-loss.md).

## Scenario C — whole box lost (full offsite rebuild)

Both pools gone. This is the only scenario that *requires* the Bitwarden keys to read the
offsite copy.

1. Fresh **TrueNAS** install on new hardware; admin password from Bitwarden.
2. Upload config + re-apply the seed (Scenario A steps 2–3) to restore the dataset layout,
   tasks, network, and the rest of the stored secrets.
3. Recreate pools/datasets per the uploaded config and [storage.md](../../storage.md).
4. **Pull data back from Hetzner** — a temporary **PULL** Cloud Sync task (or `rclone`
   directly) using the **Hetzner login + crypt password/salt from Bitwarden**, per
   [backup.md](../backup-restore/backup.md) → Restore. This is the step the emailed config can't do alone.
   - `data` leaves: `immich`, `smb_share/*`, `paperless`.
   - `apps` leaves: every service config dir.
   - **Not in backup:** `data/mediaserver` (bulk media) — re-acquire via the *arr stack
     once it's running.
5. **Databases** (Postgres and MariaDB) → restore from logical dumps ([postgres-dump.md](../backup-restore/postgres-dump.md)).
6. Stand up the stacks in dependency order — see the build order in
   [replicate-setup.md](../setup-operations/replicate-setup.md) (Komodo → tailscale → caddy/CrowdSec + VPS ingress →
   AdGuard → Authentik → app stacks → alerting → backups). Put each stack's env back from the vault
   with `scripts/secrets.sh komodo-vars`.
7. Verify the full build with the checklist at the end of
   [replicate-setup.md](../setup-operations/replicate-setup.md), then the per-boot checklist in
   [host-reboot-power-loss.md](../incident-response/host-reboot-power-loss.md).

## After any recovery

- [ ] Re-run a Cloud Sync task and confirm encrypted files land in Hetzner ([backup.md](../backup-restore/backup.md)).
- [ ] Confirm the **daily config email** (02:15) and **nightly pg_dump** (02:30) still fire
      ([scheduled-tasks.md](../../scheduled-tasks.md)).

- [ ] If you re-keyed anything (new seed, new crypt password), **update Bitwarden immediately** —
      a backup you can't decrypt is no backup.
