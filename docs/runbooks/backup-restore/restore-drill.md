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

## Silent-failure heartbeats

The nightly local scripts support an **Uptime-Kuma push monitor** so the job silently
*not running* is itself an alert (cron disabled, mail OAuth token expired, script path moved). The
monitors live on the [A1 Kuma](../../services/a1-vps-kuma.md), outside the house:

| Script | Host file with the push URL | Kuma monitor type |
| --- | --- | --- |
| [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) | `/root/.config/pg-dump-kuma-push.url` | Push, ~26 h interval |
| [`truenas-config-email.sh`](../../../scripts/truenas-config-email.sh) | `/root/.config/config-email-kuma-push.url` | Push, ~26 h interval |
| [`a1-file-backup.sh`](../../../scripts/a1-file-backup.sh) | `/root/.config/a1-file-backup-kuma-push.url` | Push, ~26 h interval |

Setup (once): in Kuma create a **Push** monitor per job (interval a bit over 24 h so a single
late run doesn't false-alarm), copy its push URL into the matching host file
(`echo 'https://kuma…/api/push/XXXX?status=up' | sudo tee /root/.config/pg-dump-kuma-push.url`),
`chmod 600`. On the next successful nightly run the monitor goes green; miss a night → Kuma
alerts. No file = the scripts skip the ping (safe default), and failures still email.

## Drill log

| Date | Config pull (step 1) | pg_dump restore (step 2) | Freshness (step 3) | Alarms (step 4) | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-07 | ok (manual, first drill) | — | — | — | Initial one-off; formalised as this runbook |
