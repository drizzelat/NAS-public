# Runbook: Backup restore drill (quarterly)

A backup you have never restored is a hypothesis, not a backup. This drill proves the
**offsite** chain end-to-end **without touching production**: it pulls one real dataset and one
real `pg_dump` back from Hetzner, decrypts them with the crypt password/salt, and verifies the
bytes. Run it **quarterly** (and after any change to the crypt key, Hetzner login, or
[`cloudsync-chain.sh`](../../../scripts/cloudsync-chain.sh)).

> **What this catches that nightly green-runs do not:** a wrong/rotated crypt salt (backups
> upload fine but are undecryptable), a Hetzner credential drift, a `pg_dump` that is present but
> corrupt/truncated, and "I don't actually have the keys" — the failure modes that only surface
> when you try to *read* the backup.

## Cadence

| When | Action |
| --- | --- |
| **Monthly, automated** (first Sunday 05:00) | [`restore-drill-auto.sh`](../../../scripts/restore-drill-auto.sh) does step 1 unattended — see [The automated drill](#the-automated-drill) |
| Quarterly (Jan / Apr / Jul / Oct) | Full drill below |
| After crypt key / Hetzner login change | Full drill (verify new secret works) |
| After editing `cloudsync-chain.sh` or `pg-dump-backup.sh` | Steps 2–4 |

Record each run at the bottom of this file (date + result). A skipped quarter is a finding.

## Before you start — confirm you hold the keys

From Bitwarden (same list as [disaster-recovery.md](../incident-response/disaster-recovery.md)):

- [ ] Cloud Sync rclone **crypt password + salt**
- [ ] **Hetzner Storage Box** SFTP host/user/password (`u000000.your-storagebox.de`)

If you cannot produce these *now*, stop — that is the drill's first (and worst) failure. Fix it
before continuing.

## The drill

Everything lands in a scratch dataset and is deleted at the end. **Nothing production is stopped
or overwritten.**

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
SCRATCH=/mnt/apps/restore-drill && sudo mkdir -p "$SCRATCH"
```

### 1. Pull one config dataset back from Hetzner

Pick a small, non-bulk leaf — `apps/kuma` is a good candidate (small, has a real SQLite DB).
Create a temporary **PULL** Cloud Sync task (web UI → Data Protection → Cloud Sync → Add,
Direction = PULL) *or* drive rclone directly with the same Crypt remote the nightly push uses:

- Remote folder: `/backup/apps/kuma`
- Local: `$SCRATCH/kuma`
- Same crypt password + salt, `filename_encryption: false`

Run it. Success = files appear **and are readable** (not still-encrypted blobs):

```sh
ls -la "$SCRATCH/kuma"
file "$SCRATCH/kuma"/*        # expect real types (SQLite, text), not "data"
sqlite3 "$SCRATCH/kuma/kuma.db" 'PRAGMA integrity_check;'   # expect: ok
```

A wrong salt shows here: the pull "succeeds" but the files are garbage / integrity_check fails.

**Do the same pull once from the *oldest* Storage Box snapshot.** The 10-day window is the whole
defence against damage that was mirrored offsite, and the path into a snapshot is different from
the live one — `.zfs/snapshot/<oldest>/backup/apps/kuma` instead of `/backup/apps/kuma`
([backup.md → History on the Storage Box](backup.md#history-on-the-storage-box)). A path that only
works on the live mirror is a path that fails on the night it is needed. The ciphertext is the
same, so the same password and salt decrypt it.

### 2. Pull one Postgres logical dump and load it into a throwaway DB

Pick any DB dumped by [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) — e.g. `mealie`.
Its dump rode offsite inside `apps/mealie/dumps`.

```sh
# pull /backup/apps/mealie/dumps -> $SCRATCH/mealie-dumps (PULL task or rclone, as above)
ls -la "$SCRATCH/mealie-dumps"                       # newest mealie_*.sql.gz present?
gzip -t "$SCRATCH/mealie-dumps"/mealie_*.sql.gz && echo "gzip intact"
```

Load it into a **disposable** Postgres container (does **not** touch the live `mealie-db`):

```sh
newest=$(ls -1t "$SCRATCH/mealie-dumps"/mealie_*.sql.gz | head -1)
sudo docker run -d --name drill-pg -e POSTGRES_PASSWORD=drill -e POSTGRES_DB=mealie \
  -e POSTGRES_USER=mealie postgres:18
sleep 8
gunzip -c "$newest" | sudo docker exec -i drill-pg psql -U mealie -d mealie
sudo docker exec drill-pg psql -U mealie -d mealie -c '\dt' | head    # tables present?
sudo docker rm -f drill-pg
```

Restore succeeds = the dump replays without fatal errors and the tables/row counts look sane.

### 3. Verify freshness

The point is a *recent* backup, not any backup:

```sh
# newest offsite file should be from last night, not weeks ago
ls -lt "$SCRATCH/mealie-dumps" | head -3
```

Cross-check against the last green cloud-sync run in `/var/log/cloudsync-chain.log`.

### 4. Confirm the alarms actually fire

The 2026-07 rewrite made [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) email on
failure and (optionally) ping Kuma on success. Prove both once:

```sh
# force a failure: point at a bogus container name, expect an email + non-zero exit
# (edit a copy; do NOT commit) — or simply confirm the last real run's Kuma heartbeat is green.
```

Confirm the heartbeat monitors (`pg-dump`, `config-email`, `a1-file-backup`) show **up** in Kuma
and that a deliberately missed ping raises an alert. See [Silent-failure heartbeats](#silent-failure-heartbeats).

### 5. Tear down

```sh
sudo docker rm -f drill-pg 2>/dev/null || true
sudo rm -rf "$SCRATCH"
# delete the temporary PULL Cloud Sync task(s) if you made them in the UI
```

## The automated drill

[`restore-drill-auto.sh`](../../../scripts/restore-drill-auto.sh) turns "the backup exists" into
"the backup restores" every month, without waiting for a quarter nobody schedules. It does **step 1
only** — the part that proves the offsite copy decrypts — and touches nothing in production:

1. finds the one Cloud Sync task whose description contains `restore-drill PULL`;
2. re-points its local path at `/mnt/apps/restore-drill` and runs it (the crypt password and salt
   stay in the middleware — the script never reads them);
3. checks `kuma.db` is there, runs `PRAGMA integrity_check`, and compares the restored file count
   with the live `apps/kuma` dataset (a band, not equality: the live dataset moves);
4. deletes the scratch copy, mails on any failure, and pings a Kuma push monitor on success.

Cron fires it **every** Sunday 05:00 — cron ORs day-of-month with day-of-week, so the script itself
returns immediately after the 7th. `RESTORE_DRILL_FORCE=1` runs it on any day for a hand test.

### Setting it up (once)

```sh
# 1. The PULL task. Copy the template's credential AND its crypt settings without ever
#    printing them: this builds the payload inside the middleware call.
sudo midclt call cloudsync.query '[["snapshot","=",true]]' | sudo python3 -c '
import json, subprocess, sys
t = json.load(sys.stdin)[0]
payload = {
    "description": "restore-drill PULL (automated)",
    "direction": "PULL", "transfer_mode": "COPY",
    "path": "/mnt/apps/restore-drill",
    "credentials": t["credentials"]["id"],
    "attributes": dict(t["attributes"], folder="/backup/apps/kuma"),
    "enabled": False, "snapshot": False,
    # Crypt is a TASK field, not part of attributes. Without these four the task
    # pulls raw ciphertext and every file arrives as <name>.bin.
    **{k: t[k] for k in ("encryption", "filename_encryption",
                         "encryption_password", "encryption_salt")},
}
subprocess.run(["midclt", "call", "cloudsync.create", json.dumps(payload)], check=True)
'

# 2. The cron job (TrueNAS -> System -> Advanced -> Cron Jobs, run as root).
sudo midclt call cronjob.create '{"description":"monthly automated restore drill",
  "command":"/bin/sh /mnt/apps/scripts/nas/scripts/restore-drill-auto.sh",
  "user":"root","schedule":{"minute":"0","hour":"5","dom":"*","month":"*","dow":"0"},
  "enabled":true,"stdout":true,"stderr":true}'

# 3. Prove it end to end, off-schedule.
sudo RESTORE_DRILL_FORCE=1 /bin/sh /mnt/apps/scripts/nas/scripts/restore-drill-auto.sh
tail -5 /var/log/restore-drill-auto.log
```

**If the restored files come back as `kuma.db.bin`**, the crypt fields are missing from the task:
`encryption`, `filename_encryption`, `encryption_password` and `encryption_salt` live on the task,
beside `attributes`, not inside it. Copy them onto the existing task with `cloudsync.update` rather
than recreating it.

The task is left **disabled** on purpose: it has no schedule of its own and only ever runs when the
script calls `cloudsync.sync` on it. A PULL task pointed at a production path would overwrite live
data, so its `path` stays the scratch dataset and the script re-points it to the same value every
run.

## Silent-failure heartbeats

The nightly local scripts ping an **Uptime-Kuma push monitor** so the job silently
*not running* is itself an alert (cron disabled, mail OAuth token expired, script path moved). All
three were created on 2026-09-23 and are **live** on the [NAS Kuma](../../services/kuma.md) — the
[A1 Kuma](../../services/a1-vps-kuma.md) is the better home in principle (it survives the NAS), but
the house-down case is covered per host by [healthchecks.io](../setup-operations/external-heartbeat.md):

| Script | Host file with the push URL | Kuma monitor type |
| --- | --- | --- |
| [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) | `/root/.config/pg-dump-kuma-push.url` | Push, ~26 h interval |
| [`truenas-config-email.sh`](../../../scripts/truenas-config-email.sh) | `/root/.config/config-email-kuma-push.url` | Push, ~26 h interval |
| [`a1-file-backup.sh`](../../../scripts/a1-file-backup.sh) | `/root/.config/a1-file-backup-kuma-push.url` | Push, ~26 h interval |
| [`restore-drill-auto.sh`](../../../scripts/restore-drill-auto.sh) | `/root/.config/restore-drill-kuma-push.url` | Push, ~40 d interval (monthly job) |

Setup (once, as done): in Kuma create a **Push** monitor per job — interval `93600` (26 h), so a
single late run doesn't false-alarm — copy its push URL into the matching host file
(`echo 'https://kuma…/api/push/XXXX?status=up&msg=OK&ping=' | sudo tee /root/.config/pg-dump-kuma-push.url`),
`chmod 600`, then curl the URL once so the monitor leaves *Pending* before the first nightly run.
Miss a night → Kuma alerts. No file = the scripts skip the ping (safe default), and failures still email.

On a `kuma.example.com` URL the ping only works because of the TrueNAS host entry — the vhost is
`lan_only` and the NAS resolves through `1.1.1.1`, so without it the push returns HTTP 525. See
[renovate-trigger → Alerting](../setup-operations/renovate-trigger.md#alerting-dead-mans-switch).

## Drill log

| Date | Config pull (step 1) | pg_dump restore (step 2) | Freshness (step 3) | Alarms (step 4) | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-09-23 | **PASS** (automated) | not run | not run | not run | First run of [`restore-drill-auto.sh`](../../../scripts/restore-drill-auto.sh): `apps/kuma` pulled from Hetzner, `PRAGMA integrity_check` **ok**. The first attempt failed with `kuma.db is not in the restored copy` — the PULL task had been created without the crypt fields, so it pulled ciphertext (`kuma.db.bin`). Fixed on the task and in the setup block above |
| 2026-07 | ok (manual, first drill) | — | — | — | Initial one-off; formalised as this runbook |
