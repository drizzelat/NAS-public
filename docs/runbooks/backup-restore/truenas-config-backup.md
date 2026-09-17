# Runbook: TrueNAS Config Backup

## Why is this important?
Your TrueNAS configuration contains everything about your system setup: network interfaces, dataset structures, users, every scheduled task, and (with the secret seed) the encrypted service secrets including **Cloud Sync encryption passwords and salts**.

The Cloud Sync **encryption keys/salts are also stored in Bitwarden**, so a boot-drive failure does not mean losing the ability to decrypt the Hetzner backups. The config backup still matters: it restores the whole box (settings + the other stored secrets) in one step instead of rebuilding by hand.

## How to export the config

The configuration is a small `.tar` file. You should export it manually before any major TrueNAS upgrade or after significant configuration changes.

### Via the Web UI
1. Log into the TrueNAS Web UI.
2. Go to **System Settings** → **General**.
3. Click **Manage Configuration** → **Download File** (in newer Scale versions, it's often a button at the top right).
4. **CRITICAL:** Check **Export Password Secret Seed** (this ensures your Cloud Sync keys and password hashes are included).
5. Click **Save**.

Store this `.tar` file securely in your password manager, encrypted cloud storage, or on a physical USB drive separate from the NAS.

## Automated Backup (email)

**Status: live.** A root cron job (daily 02:15) runs [`scripts/truenas-config-email.sh`](../../../scripts/truenas-config-email.sh) straight out of the auto-pulled repo clone (`/mnt/apps/scripts/nas/scripts/truenas-config-email.sh`). We email the config to ourselves instead of dropping it into a cloud-synced dataset, so it never lands in an unrelated place. The script:

- tars **`/data/freenas-v1.db` only** (the config DB) — the secret seed `pwenc_secret` is **deliberately excluded** (see security note),
- emails the tarball as a real MIME **attachment** via the `mail.send` middleware job, using the GUI SMTP settings (the system exim is local-only and cannot relay externally, so a plain `sendmail`/`mailx` would silently not deliver),
- recipient defaults to `you@example.com`; pass a different one as `$1`.

**Why an attachment via `/_upload`, not inline:** `mail.send` over the local WebSocket caps messages at 64 kB — too small for the config once base64'd inline. Real attachments are passed to the job through the middleware `/_upload` HTTP endpoint (nginx → `127.0.0.1:6000`) as a JSON list of attachment dicts (base64 `content` + MIME headers). The script authenticates with a **short-lived, single-use token** minted per run via `auth.generate_token` (header `Authorization: Token …`) — **no API key is stored** anywhere.

### Security note — why the seed is excluded

`freenas-v1.db` stores secrets *encrypted*; `pwenc_secret` is the seed that decrypts them. Shipping both would mean anyone who got hold of the email could decrypt **everything** — including the Cloud Sync SFTP login and the rclone crypt password, i.e. full read access to (and deletion of) the offsite Hetzner backups, plus TLS private keys, the SMTP password, account hashes, etc.

So the email carries the **config DB only**. A leaked email is then just encrypted blobs, useless without the seed. The seed lives in Bitwarden instead (see below). Trade-off: a bare-metal restore needs the seed re-applied from Bitwarden before the stored secrets become usable.

### After editing the script

Push to `main`. The on-NAS clone pulls it within 15 minutes
([nas-repo-autopull](../setup-operations/nas-repo-autopull.md)) and the next 02:15 run uses it —
there is nothing to copy. To verify now (sends a real email; check the `mail.send` job result is
SUCCESS):

```sh
# from the repo root
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111 \
  'sudo /bin/sh /mnt/apps/scripts/nas/scripts/truenas-config-email.sh'
```

> The hand-copied `/mnt/apps/scripts/truenas-config-email.sh` from before the auto-pull is a dead
> copy no cron runs — do not copy over it or run it.

The cron job (id 3, `truenas config email`, daily 02:15, user root) is already registered.

> TrueNAS also keeps an internal daily copy of the config in the `system` dataset, and you can still export manually (steps above) before any major upgrade.

## What must live in Bitwarden

Because the emailed config does not carry the seed, these are the items that are **not** recoverable from the email alone. Store each in Bitwarden:

| Item | What it is / why | How to get it |
| --- | --- | --- |
| **`pwenc_secret`** (the seed) | Decrypts every secret in the config DB. Without it, a restored config has unusable encrypted secrets. | On the host: `sudo base64 /data/pwenc_secret` — paste the base64 string into Bitwarden. Re-capture only if you re-key (rare). |
| **Cloud Sync crypt password + salt** | The rclone Crypt passphrase/salt that encrypts the Hetzner backups. Needed to decrypt backups even outside TrueNAS. | From when the Cloud Sync task was created (already stored, per existing notes). |
| **Hetzner Storage Box login** | SFTP host/user/password for `u000000.your-storagebox.de`. Needed to reach the offsite copy directly. | Hetzner Robot / your records. |
| **TrueNAS admin login** | `truenas_admin` / root password to get into a freshly reinstalled box. | Your records. |
| **age vault passphrase** | Unwraps `secrets.enc/age-key.age`, which decrypts every stack's env and the host SSH keys. Not a TrueNAS secret, but a rebuild stalls without it. | Chosen at `scripts/secrets.sh init` ([secret-sync](../setup-operations/secret-sync.md)). |

`freenas-v1.db` itself does **not** need to go in Bitwarden — it arrives by email daily.

## Disaster recovery

How recovery works now, by scenario:

### A) Boot drive dies, pools intact (most common)

1. Reinstall TrueNAS SCALE, log in with the admin password (Bitwarden).
2. **System → General → Manage Configuration → Upload Config**, upload the latest `freenas-v1.db` tarball from email.
3. Re-apply the seed: the upload path expects the seed alongside the DB. Since the email omits it, restore the seed from Bitwarden first — recreate `/data/pwenc_secret` from the stored base64 (`base64 -d > /data/pwenc_secret`) **or** rebuild the config tarball locally as `freenas-v1.db` + `pwenc_secret` and upload that. Without the seed, stored secrets (Cloud Sync creds, certs, SMTP) come back blank and must be re-entered.
4. Import the existing pools; services resume.

### B) Whole box / both pools lost (full offsite rebuild)

1. Fresh TrueNAS install, admin password from Bitwarden.
2. Recreate pools/datasets (the uploaded config defines the layout).
3. Pull data back from Hetzner: a temporary **PULL** Cloud Sync task (or `rclone` directly) using the **Hetzner login + crypt password/salt from Bitwarden**. This is the step that *requires* the Bitwarden items — the emailed config can't decrypt Hetzner on its own.
4. Upload config + seed as in (A) to restore settings and the rest of the secrets.

**Key point:** the email gets you back the *configuration*; **Bitwarden gets you back the *keys*.** You need both for a clean restore, and they are stored in two independent places on purpose.
