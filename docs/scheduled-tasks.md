# Scheduled Tasks Overview

Every recurring/timed job across the NAS, and where it is defined. Sources:

1. **Container schedule** — defined in a stack's `docker-compose.yml` (in this repo).
2. **TrueNAS Cron Jobs** — TrueNAS UI → *System → Advanced → Cron Jobs* (run as root). Not in the compose files; the script lives in `scripts/`. The host runs each one **straight out of a repo clone** at `/mnt/apps/scripts/nas`, auto-pulled from `main` every 15 min — a push is all it takes to update a cron script. See [NAS repo auto-pull](runbooks/setup-operations/nas-repo-autopull.md).
3. **TrueNAS Cloud Sync** — TrueNAS UI → *Data Protection → Cloud Sync Tasks*.
4. **TrueNAS Periodic Snapshot Tasks** — *Data Protection → Periodic Snapshot Tasks*.
5. **TrueNAS Disk health** — S.M.A.R.T. tests (*Data Protection → S.M.A.R.T. Tests*) and pool scrubs (*Data Protection → Scrub Tasks*).
6. **FRITZ!Box firmware auto-update** — router-side, set in the FRITZ!Box UI (*System → Update → AutoUpdate*). Not TrueNAS; reboots the router (WAN drop) so it must miss the WAN-dependent jobs.
7. **VPS OS updates** — Ubuntu `unattended-upgrades` on the micro and the A1. A drop-in on `apt-daily-upgrade.timer` sets when it runs, `/etc/apt/apt.conf.d/60nas-auto-updates` what installs and when to reboot. Host clocks are UTC. See [OS updates](runbooks/setup-operations/os-updates.md).

All TrueNAS tasks are managed via the UI or `midclt`/API. All times are **Europe/Vienna** unless marked UTC. The nightly window is deliberately ordered: snapshots (01:00) → A1 file sync (02:00) → config email (02:15) → dumps (02:30) → cloud sync (03:00, one sequential chain: all `data` leaves, then all `apps` leaves). Disk health runs early-morning / overnight on its own cadence.

> **Source of truth.** This file is hand-maintained from the live TrueNAS config. To re-verify, query the host (see [Verifying against the live host](#verifying-against-the-live-host)).

## Timeline (nightly)

| Time | Task | Type | Defined in |
| --- | --- | --- | --- |
| every 1 min | **Dead-man's switch** — ping this host's healthchecks.io check, or `/fail` it if the guard container is not running. Runs on **all three hosts** (NAS, A1, micro), each with its own check, so an outage of everything here is raised by an alerter not operated here | TrueNAS cron + `/etc/cron.d` on the VPS hosts | [`scripts/healthchecks-ping.sh`](../scripts/healthchecks-ping.sh) · [runbook](runbooks/setup-operations/external-heartbeat.md) |
| every 15 min (:07,:22,:37,:52) | Auto-pull the on-host repo clone to `origin/main` (feeds the cron scripts below) | TrueNAS cron | [`scripts/git-pull-nas.sh`](../scripts/git-pull-nas.sh) · [runbook](runbooks/setup-operations/nas-repo-autopull.md) |
| Mon 00:00 | Scrub pool `data` (threshold 35 days) | Scrub | TrueNAS |
| Tue 00:00 | Scrub pool `apps` (threshold 35 days) | Scrub | TrueNAS |
| every 4h (00,04,08,12,16,20) | ZFS snapshot of `apps` — 3-day retention | Snapshot task | TrueNAS |
| 01:00 daily | ZFS snapshot of `data/smb_share`, `data/immich`, `data/paperless` — 14-day retention | Snapshot task | TrueNAS |
| 22:15 UTC + up to 10 min (00:15 Vienna summer, 23:15 winter) | **A1 OS updates**: Ubuntu security and `-updates`, Docker 29.x point releases. A Docker update restarts every container (~25 s without Matrix); one that needs a reboot schedules the 23:15 UTC row | A1 host (`apt-daily-upgrade.timer`) | [runbook](runbooks/setup-operations/os-updates.md) |
| 23:15 UTC (01:15 Vienna summer, 00:15 winter) | **A1 reboot**, only when that night's update run left `/var/run/reboot-required` (kernel, libc). ~80 s without Matrix, NTP, Tor bridge and A1 Kuma; done well before the 02:00 A1 file sync | A1 host (`unattended-upgrades`) | [runbook](runbooks/setup-operations/os-updates.md) |
| 22:45 UTC + up to 10 min (00:45 Vienna summer, 23:45 winter) | **Micro VPS OS updates**, same set. A Docker update restarts nginx, so public sites drop briefly; a required reboot goes to the 23:45 UTC row | micro VPS host (`apt-daily-upgrade.timer`) | [runbook](runbooks/setup-operations/os-updates.md) |
| 23:45 UTC (01:45 Vienna summer, 00:45 winter) | **Micro VPS reboot**, same condition. ~2 min without public sites; clear of the 00:17 edge probe, 30 min after the A1 so only one host is down at a time | micro VPS host (`unattended-upgrades`) | [runbook](runbooks/setup-operations/os-updates.md) |
| 00:15 UTC + up to 10 min (02:15 Vienna summer, 01:15 winter) | **Runner VM OS updates**, the same set as the VPS hosts. A required reboot goes to the 00:45 UTC row | runner VM (`apt-daily-upgrade.timer`) | [runbook](runbooks/setup-operations/os-updates.md#runner-vm) |
| 00:45 UTC (02:45 Vienna summer, 01:45 winter) | **Runner VM reboot**, same condition. About a minute with the Komodo Server `runner-vm` `NotOk` | runner VM (`unattended-upgrades`) | [runbook](runbooks/setup-operations/os-updates.md#runner-vm) |
| 01:30 daily | FRITZ!Box firmware auto-update window (~3–5 min WAN drop on reboot) | FRITZ!Box | FRITZ!Box UI |
| 02:00 daily (Mon–Fri, Sun) | S.M.A.R.T. SHORT test, all SATA disks (NVMe is skipped — see below) | SMART | TrueNAS |
| 02:00 Sat | S.M.A.R.T. LONG test, all SATA disks (NVMe is skipped — see below) | SMART | TrueNAS |
| 02:05 daily (Mon–Fri, Sun) | S.M.A.R.T. SHORT self-test, NVMe (`nvme0n1` = the whole `apps` pool) | TrueNAS cron | [`scripts/nvme-smart-test.sh`](../scripts/nvme-smart-test.sh) |
| 02:05 Sat | S.M.A.R.T. LONG self-test, NVMe | TrueNAS cron | [`scripts/nvme-smart-test.sh`](../scripts/nvme-smart-test.sh) |
| 02:00 | Mirror the A1's non-database files to `/mnt/apps/a1-matrix/` over the tailnet — Synapse media store (~9.3 GB) and the external watchdog's Kuma DB — each via its own read-only `rrsync` key | TrueNAS cron | [`scripts/a1-file-backup.sh`](../scripts/a1-file-backup.sh) · [runbook](runbooks/backup-restore/a1-matrix-backup.md) |
| 02:15 | TrueNAS config backup → email (config DB only, as attachment) | TrueNAS cron | [`scripts/truenas-config-email.sh`](../scripts/truenas-config-email.sh) · [runbook](runbooks/backup-restore/truenas-config-backup.md) |
| 02:30 | Logical DB dumps (`pg_dump` / `mariadb-dump`) of every container carrying `nas.backup.dump=true` — on the NAS **and** on the A1 over the tailnet | TrueNAS cron | [`scripts/pg-dump-backup.sh`](../scripts/pg-dump-backup.sh) · [runbook](runbooks/backup-restore/postgres-dump.md) |
| 03:00 | Cloud Sync chain → Hetzner: one template task re-pointed at all `data` leaves, then all `apps` leaves, run **one at a time**. Starts by sweeping leaked `@cloud_sync-*` temp snapshots older than 2 days (an interrupted run leaves them behind and nothing else collects them — 19 were found holding ~4.4 GB on 2026-08-13) | TrueNAS cron → Cloud Sync | [`scripts/cloudsync-chain.sh`](../scripts/cloudsync-chain.sh) · [runbook](runbooks/backup-restore/backup.md#leaked-temp-snapshots) |
| 03:40 daily (host cron → `workflow_dispatch`) | **Tor bridge image freshness checks, primary trigger** (WebTunnel and obfs4, one run each): compare each published arm64 bridge image with what a build would pull now (Go patch release, Debian base) and dry-run `apt-get upgrade` inside it (Debian security fixes, new Tor). It rebuilds and pushes only on a difference; Renovate's 04:15 run turns a push into the compose PR and the 05:20 sweep merges it | TrueNAS cron → GitHub Actions | [`scripts/tor-bridge-image-trigger.sh`](../scripts/tor-bridge-image-trigger.sh) · [runbook](runbooks/setup-operations/renovate-trigger.md#tor-bridge-image-trigger) · [`build-webtunnel-image.yml`](../.github/workflows/build-webtunnel-image.yml) · [`build-obfs4-image.yml`](../.github/workflows/build-obfs4-image.yml) |
| 03:10 UTC (WebTunnel), 03:25 UTC (obfs4) | Same checks, **fallback trigger** (GitHub `schedule:`, best-effort). On a day the host cron already fired, each finds its image current and pushes nothing | GitHub Actions (schedule) | [`build-webtunnel-image.yml`](../.github/workflows/build-webtunnel-image.yml) · [`build-obfs4-image.yml`](../.github/workflows/build-obfs4-image.yml) · service docs: [WebTunnel](services/a1-vps-webtunnel.md#image-and-security-updates), [obfs4](services/a1-vps-tor-bridge.md#image-and-security-updates) |
| Sun 04:30 | **Docker image prune** (unused images older than 7 d). The two VPS hosts run the prune alone from a systemd timer, Sun 04:30 UTC | TrueNAS cron · systemd timer on the VPS hosts | [`scripts/docker-image-prune.sh`](../scripts/docker-image-prune.sh) · [runbook](runbooks/setup-operations/docker-image-prune.md) |
| Wed 04:45 | **Kiwix seeding** — keep qBittorrent seeding the newest Kiwix ZIM of each configured flavour (offline Wikipedia, Gutenberg) inside a 300 GB budget, and remove the copies they supersede once the new one is complete. Mails when a mirror listing does not parse, a `.torrent` does not resolve, or the run aborts | TrueNAS cron | [`scripts/kiwix-seed.sh`](../scripts/kiwix-seed.sh) · [runbook](runbooks/setup-operations/kiwix-seeding.md) |
| 04:15 and 05:15 Vienna (host cron → `workflow_dispatch`) | Fire the self-hosted Renovate run: opens/refreshes PRs (and merges github-actions bumps, the only thing Renovate still merges) so freshly-reviewed stack PRs are waiting for the sweep below. The 04:15 pass gives each new PR an hour for its review to finish before the 05:20 sweep. GitHub's hourly `schedule:` cron runs too but is best-effort/late | TrueNAS cron → GitHub Actions | [`scripts/renovate-trigger.sh`](../scripts/renovate-trigger.sh) · [runbook](runbooks/setup-operations/renovate-trigger.md) · [`renovate.yml`](../.github/workflows/renovate.yml) · [`renovate.json`](../renovate.json) |
| 05:20, 05:35, 05:50 Vienna (host cron → `workflow_dispatch`) | **Merge sweep, primary trigger:** merge every Renovate stack PR whose `renovate-review` commit status is green (`DELTA: NOOP` or `RISK: LOW`). Each merge fires `deploy-stacks`, so redeploys land while nobody is using the NAS. Merges are paced: the sweep waits for one deploy to finish before merging the next (GitHub keeps only one *pending* run per concurrency group, so back-to-back merges cancelled the waiting run and stranded the pin — 5 stacks were left undeployed for up to 14 days, found 2026-08-13). Starts at :20 so the 05:15 Renovate run has opened and reviewed the morning's PRs first | TrueNAS cron → GitHub Actions | [`scripts/merge-sweep-trigger.sh`](../scripts/merge-sweep-trigger.sh) · [runbook](runbooks/setup-operations/renovate-trigger.md#merge-sweep-trigger) · [`renovate-pr-review.yml`](../.github/workflows/renovate-pr-review.yml) (`window-merge` job) |
| every 10 min of 03 + 04 UTC — the job merges only when it is 05:xx Berlin (covers both DST offsets) | Same merge sweep, **fallback trigger** for when the NAS is down at 05:00. GitHub's `schedule:` cron is best-effort: on 2026-07-30 one of eight slots fired, 50 min late, outside the window — which is why the host cron above exists | GitHub Actions (schedule) | [`renovate-pr-review.yml`](../.github/workflows/renovate-pr-review.yml) (`window-merge` job) · [runbook](runbooks/setup-operations/renovate-pr-review.md) |
| 08:30 UTC (~10:30 Vienna summer) | **Stale-clearance alarm:** goes red (→ GitHub failure email) if a stack PR has had a green `renovate-review` for over 24 h and is still open — i.e. the sweep stopped working. Needed because a cleared PR now merges silently, so a broken sweep otherwise looks exactly like a quiet week | GitHub Actions (schedule) | [`renovate-pr-review.yml`](../.github/workflows/renovate-pr-review.yml) (`stale-clearance` job) |
| 06:30 Vienna (host cron → `workflow_dispatch`) | **Health check, primary trigger:** Claude health check (19 checks): TrueNAS alerts, failed units + clock sync, pools, SMART, scrub age, snapshot recency **and retention**, storage drift, dump freshness **and integrity**, cloud-sync chain result, auto-pull clone, boot-guard drop-in, deployed stacks vs repo (incl. image digest drift), container state (all Komodo Servers), cert expiry, **Cloudflare range drift in the two files that pin them**, **24 h edge-log scan (scanner paths, external 401/403, real-client-IP canary)** and **non-CAPI CrowdSec decisions**. `HEALTH: FAIL` turns the run red → GitHub failure email | TrueNAS cron → GitHub Actions | [`scripts/nas-health-trigger.sh`](../scripts/nas-health-trigger.sh) · [`nas-health-check.yml`](../.github/workflows/nas-health-check.yml) · [checklist](../.github/nas-health-check.md) · [runbook](runbooks/setup-operations/nas-health-check.md) |
| 06:30 UTC — the job exits early unless the day has no dispatched run | Same health check, **fallback trigger** for a day the host cron never fired. GitHub `schedule:` is not a NAS-down fallback here: the runner is a container *on* the NAS, so nothing runs either way — it only covers a broken host cron, and it skips (and logs a `::warning::`) when the 06:30 dispatch already landed, because a run costs ~$1.70 | GitHub Actions (schedule) | [`nas-health-check.yml`](../.github/workflows/nas-health-check.yml) · [runbook](runbooks/setup-operations/nas-health-check.md#on-time-trigger) |
| :17 every 6h Vienna (host cron → `workflow_dispatch`) | **Edge access policy probe, primary trigger:** asserts that no admin hostname is reachable from the internet. Two jobs, because the layers mask each other — the VPS SNI allowlist checked from a GitHub runner straight at the VPS public IP (a blocked host must have its connection closed before TLS; a proxy-shaped answer means Layer 1 failed open — Cloudflare is out of the path because it serves runner IPs a managed challenge), and Caddy's `@lan` client-IP rule checked from the ingress VPS itself over a PROXY-protocol header. On a timer rather than PR-triggered: the drift it catches happens outside git | TrueNAS cron → GitHub Actions | [`scripts/edge-probe-trigger.sh`](../scripts/edge-probe-trigger.sh) · [`edge-access-policy.yml`](../.github/workflows/edge-access-policy.yml) · [`scripts/edge-access-probe.sh`](../scripts/edge-access-probe.sh) · [runbook](runbooks/setup-operations/edge-access-policy-probe.md#on-time-trigger) |
| 08:17 UTC — the `guard` job skips the run unless the day has no dispatched run | Same probe, **fallback trigger**. Unlike the health check's this one *does* survive a NAS outage — both jobs run on `ubuntu-latest`, not the self-hosted runner — so it is what still fires when the host cron cannot dispatch. It skips (and logs a `::warning::`) when a dispatch already concluded today. A deliberate NAS outage will make it go red, correctly | GitHub Actions (schedule) | [`edge-access-policy.yml`](../.github/workflows/edge-access-policy.yml) · [runbook](runbooks/setup-operations/edge-access-policy-probe.md#the-fallback-and-why-it-is-guarded) |
| :47 at 03/09/15/21 Vienna (host cron → `workflow_dispatch`) | **Deploy-state probe, primary trigger:** deterministic assertion that the running estate matches the repo — every stack folder deployed and active on its routed endpoint, running digests equal to the pins (the health check's own drift script), no orphaned services or unexplained compose projects, every container running or cleanly exited and none unhealthy, caddy on every `proxy_*` network, host-installed scripts matching the repo. An exit code, no model: the Komodo migration's gate | TrueNAS cron → GitHub Actions (self-hosted runner) | [`scripts/deploy-state-trigger.sh`](../scripts/deploy-state-trigger.sh) · [`deploy-state-probe.yml`](../.github/workflows/deploy-state-probe.yml) · [`deploy-state-probe.sh`](../.github/scripts/deploy-state-probe.sh) · [runbook](runbooks/setup-operations/deploy-state-probe.md#on-time-trigger) |
| 10:47 UTC — the `guard` job skips the run unless the day has no dispatched run | Same probe, **fallback trigger**. Its probe job needs the NAS runner, so like the health check's fallback it cannot fire during a NAS outage | GitHub Actions (schedule) | [`deploy-state-probe.yml`](../.github/workflows/deploy-state-probe.yml) · [runbook](runbooks/setup-operations/deploy-state-probe.md#the-fallback-and-why-it-is-guarded) |

> **At boot, not on a clock** — two TrueNAS *Init/Shutdown Scripts* (POSTINIT): `ethtool --set-eee enp2s0 eee off` ([NIC packet loss](runbooks/incident-response/nas-nic-packet-loss.md)), and `docker-boot-guard.sh` ([docker-image-prune](runbooks/setup-operations/docker-image-prune.md)).

> **No host-side auto-update job.** Watchtower was removed (2026-06). Every stack image is pinned `tag@sha256:digest`. Bumps are not applied on the host — the self-hosted **Renovate** GitHub Action raises the PRs (see below); a merge pushes the pin and `deploy-stacks` deploys it through Komodo. The Komodo control plane itself (Core, Mongo, the peripheries) is never auto-merged: its PRs are merged by hand and applied by pressing Deploy (Core) or by hand over SSH (peripheries). See each service's *Upgrade* section.

## Details

### NAS repo auto-pull — every 15 min (TrueNAS cron)

The cron scripts on this page are **not** hand-copied onto the host any more. The host keeps a clone of this repo at `/mnt/apps/scripts/nas`; [`scripts/git-pull-nas.sh`](../scripts/git-pull-nas.sh) (cron id 5, `:07/:22/:37/:52`) fast-forwards it to `origin/main` (read-only deploy key), and each backup cron runs `/bin/sh /mnt/apps/scripts/nas/scripts/<name>.sh`. So a push to `main` is the whole update path. The puller is deployed **outside** the clone on purpose (a repo must not be able to overwrite its own updater). Full detail in the [NAS repo auto-pull runbook](runbooks/setup-operations/nas-repo-autopull.md).

### TrueNAS config backup — daily 02:15 (TrueNAS cron)

`scripts/truenas-config-email.sh` tars `/data/freenas-v1.db` (full system config; **config DB only**) and **emails** it as a real MIME **attachment** via the configured SMTP, so the config never lands in an unrelated dataset. It mints a short-lived single-use token per run and posts the attachment through the middleware `/_upload` endpoint (the WebSocket path caps at 64 kB) — no API key is stored. The secret seed (`pwenc_secret`) is **deliberately excluded** — without it a leaked email is just encrypted blobs. The seed and the Cloud Sync encryption password/salt live in Bitwarden; restore re-applies the seed from there. See [the runbook](runbooks/backup-restore/truenas-config-backup.md).

### Postgres dumps — daily 02:30 (TrueNAS cron)

`scripts/pg-dump-backup.sh` writes one gzipped dump per DB into a `dumps/` dir that already sits inside a backed-up dataset, so the 03:00 cloud-sync chain carries it offsite. Retention: 7 days. Runs before the cloud-sync window on purpose.

**Targets are discovered, not listed.** Each database service carries `nas.backup.dump=true` plus `nas.backup.{user,db,dir}` labels in its own compose file, so a new DB stack is backed up by construction. Currently: `authentik`, `immich`, `paperless`, `mealie`, `gamevault`, `romm` (MariaDB) on the NAS, and `synapse` + `mautrix_whatsapp` on the **A1** via a `docker -H ssh://` host entry. Discovery brings its own risk — a DB dropping silently *out* of the set — so empty discovery is a hard error and every good run records its set in `/root/.local/state/nas-db-dump-discovered` for the next run to diff. See [postgres-dump.md](runbooks/backup-restore/postgres-dump.md).

**Alerting (2026-07).** A failed *or skipped* dump now **emails** a summary via `mail.send` (same path as the cloud-sync chain) and exits non-zero. Before this, a pipe-subshell bug made the script always exit 0 and it had no mail path — a failing dump was fully silent, quietly rotting the safe restore path. On **full** success it optionally pings an Uptime-Kuma **push** monitor if `/root/.config/pg-dump-kuma-push.url` holds a URL, so the job *not running at all* is itself an alert. Same heartbeat wired into the 02:15 config email (`/root/.config/config-email-kuma-push.url`). Setup: [restore-drill.md](runbooks/backup-restore/restore-drill.md#silent-failure-heartbeats).

### A1 file sync — daily 02:00 (TrueNAS cron)

`scripts/a1-file-backup.sh` rsyncs the Ampere A1's non-database files into `apps/a1-matrix`, a dataset the 03:00 chain discovers on its own: the Synapse media store, and the external watchdog's Kuma state (which lived in an un-backed-up named volume until 2026-08-21). `--delete` keeps each a true mirror; deletion history is the 4-hourly `apps` snapshot task and the offsite copy.

The script names **SSH aliases, not paths**, because each alias carries a key the A1 pins to one `rrsync -ro <root>` forced command — so the alias *is* the access scope and no key can read outside it or open a shell. Single-instance via `flock`; a lock still held at the next nightly run alerts rather than being skipped. Failure emails and an optional Kuma heartbeat (`/root/.config/a1-file-backup-kuma-push.url`) work exactly like the dump job's. Runbook: [a1-matrix-backup.md](runbooks/backup-restore/a1-matrix-backup.md).

### Cloud Sync → Hetzner (snapshot-based, PUSH/SYNC over SFTP)

**One template task, re-pointed per leaf dataset** — it does not self-schedule. The template's own cron schedule is **disabled** (`enabled: false`); a single TrueNAS cron at **03:00** runs [`scripts/cloudsync-chain.sh`](../scripts/cloudsync-chain.sh), which rewrites the template's `path`/`folder`/`exclude` for each leaf and runs it **sequentially** — all `data` leaves first, then all `apps` leaves, the next leaf starting only after the previous reaches a terminal state. (Previously there was one task *per* leaf; that cluttered the Cloud Sync UI, so the dozens of tasks were collapsed to this one template.)

**Why the chain.** Running datasets concurrently overruns the Hetzner Storage Box's concurrent-connection cap: long-running ones (jellyfin, immich, authentik) hold their SFTP connections open and overlap the wave of small ones, so combined SSH channels exceed the cap and the box refuses new channels (`ssh: unexpected packet in response to channel open`, `connection refused`, `connection lost`). Serial execution guarantees at most one dataset's connections exist at any moment. `cloudsync.sync` runs the template regardless of its `enabled` flag, so disabling its schedule only stops auto-firing — the chain still drives it. An exclusive lock stops two runs stomping the shared template mid-sync.

The dataset list is derived live from `pool.dataset.query` (data whitelist + all apps leaves minus exclusions), so a newly created **apps** leaf joins automatically with no edit; a new **data** leaf needs adding to `DATA_INCLUDE` in the script. The remote `/backup/<pool>/<rel>` layout on Hetzner is unchanged. `midclt`/API management + one-time migration steps are in the [backup runbook](runbooks/backup-restore/backup.md).

**Failure alerting is script-driven, not TrueNAS's.** On any dataset failure (or a whole-run abort) the script emails a dataset-named summary via `mail.send` to the configured `fromemail`; success is silent. TrueNAS's own *Cloud Sync task failed* alert / cron-output email are **not** relied on — they target the (unset) admin-account address and would name only the template task. See [Failure alerts](runbooks/backup-restore/backup.md#failure-alerts-email).

### Renovate — dependency update PRs (GitHub, not host)

[`renovate.json`](../renovate.json) is the config; **Renovate runs self-hosted** from [`renovate.yml`](../.github/workflows/renovate.yml) (a GitHub Action on `ubuntu-latest`) — **not** the Mend-hosted app. Why self-host: control over when it runs, and the `workflow` scope it needs to update `.github/workflows/*`. (It was originally about hitting the `automergeSchedule` window; stack merges no longer happen through Renovate at all — see the merge policy below.)

**Two clocks now, not one.** `renovate.yml` runs **hourly** and *opens/refreshes* PRs (there is no top-level `schedule` in renovate.json); TrueNAS crons additionally hit the REST `workflow_dispatch` endpoint at **04:15 and 05:15 Vienna** — see [`scripts/renovate-trigger.sh`](../scripts/renovate-trigger.sh) and the [Renovate trigger runbook](runbooks/setup-operations/renovate-trigger.md). Those were built when Renovate did the merging and merged **one PR per run**, which drained the queue at one stack per day; since stack merges moved to [`renovate-pr-review.yml`](../.github/workflows/renovate-pr-review.yml)'s sweep — which merges *every* cleared PR in one pass — their job is only to make sure fresh PRs exist and are reviewed before the sweep runs at 05:20. Paired with `"rebaseWhen": "conflicted"` in `renovate.json`, which stops Renovate rebasing every open branch each time `main` moves (that reset all their check-runs to pending and blocked further merges; `main` has `strict: false`, so behind-base branches merge fine). Renovate watches every stack's `docker-compose.yml`, keeps each image pinned by digest (`pinDigests`), and opens PRs to bump pins. GitHub Actions in workflows are digest-pinned too (`helpers:pinGitHubActionDigests`). PRs open as soon as a release exists — no release-age soak; the `minimumReleaseAge`/`internalChecksFilter` soak was removed because fast-releasing images kept resetting the soak clock, stranding PRs that then needed hand-merges.

**Setup / required config:**

- Secrets `RENOVATE_APP_CLIENT_ID` + `RENOVATE_APP_PRIVATE_KEY` — a **GitHub App installed on this repo alone**; `renovate.yml` mints a 1 h installation token from them per run. It replaced a classic PAT whose `repo` + `workflow` scopes were account-wide; an App can hold `Checks: read` (which automerge needs and fine-grained PATs cannot grant) scoped to one repository. Setup, permission table and cutover: [Renovate as a GitHub App](runbooks/setup-operations/renovate-github-app.md). `GITHUB_TOKEN` is intentionally not used: its PRs would not trigger `compose-validate` (loop-prevention), so the required check would never run and automerge would stall.
- **Deactivate the Mend Renovate app for this repo** (github.com → Settings → Applications → Renovate → Configure → remove `drizzelat/NAS`). Otherwise both Renovates open PRs and fight.
- **On-time trigger token** — a dedicated fine-grained PAT (**Actions: read+write** on `drizzelat/NAS` only) at `/root/.config/renovate-trigger.token` on the NAS, read by [`scripts/renovate-trigger.sh`](../scripts/renovate-trigger.sh), [`scripts/merge-sweep-trigger.sh`](../scripts/merge-sweep-trigger.sh), [`scripts/nas-health-trigger.sh`](../scripts/nas-health-trigger.sh), [`scripts/edge-probe-trigger.sh`](../scripts/edge-probe-trigger.sh) and [`scripts/deploy-state-trigger.sh`](../scripts/deploy-state-trigger.sh). Separate from, and narrower than, the Renovate App token above — it can only fire workflow runs. Setup + cron entries in the [Renovate trigger runbook](runbooks/setup-operations/renovate-trigger.md).
- Manual run: Actions tab → **renovate** → *Run workflow* (`workflow_dispatch`), or `sudo /bin/sh /mnt/apps/scripts/nas/scripts/renovate-trigger.sh` on the host.

**Merge policy — PRs anytime; every stack PR is reviewed, and only a no-op or `RISK: LOW` merges, at 05:00–06:00:**

Renovate **no longer merges stack images at all** (`automerge: false` for `docker-compose`). [`renovate-pr-review.yml`](../.github/workflows/renovate-pr-review.yml) is the only path onto `main`: it runs both layers on every stack PR (registry-API image delta + a Claude risk verdict) and its `window-merge` sweep merges the cleared ones inside the 05:00–06:00 window. Why the change: mealie `v3.20.1 → v3.22.0` (PR #92) was a routine *minor* that bundled v3.21.0's mandatory OIDC `email_verified` claim — Authentik's default mapping sends `False`, so the 05:00 automerge would have locked every account out of a stack with no password login. Update type says nothing about blast radius.

**The verdict is the `renovate-review` commit status**, posted on the PR's head SHA — green = cleared, red = a human has to look. It is a **required check on `main`** (alongside `validate`), so a flagged PR is held back from a hand-merge too; `enforce_admins` is off, so you can still override deliberately. Because a status belongs to one commit, a force-push voids the clearance by itself. Every PR gets the status, including hand-written ones (a `gate-passthrough` job posts a green one) — a required status *context* has no "skipped" state, so a context that is never posted would block that PR forever.

**You only get a PR comment — and therefore an email — when a PR needs you.** A cleared PR is silent; an already-existing comment is edited rather than re-posted (edits do not notify). The dead-man's switch for that silence is the `stale-clearance` alarm at 08:30 UTC: red, and a failure email, if anything has been cleared for over 24 h and is still open.

| Update type | Bundling | Merge |
| --- | --- | --- |
| pin/pinDigest + patch + digest | minor+patch+digest: one grouped PR per stack folder (`{{packageFileDir}}`) — one merge = one stack redeploy | **Reviewed, then merged in-window if `renovate-review` is green (`DELTA: NOOP` or `RISK: LOW`)** |
| minor | Grouped with patch/digest per stack, labelled `minor-update` for visibility | Same gate — judged by release-note contents, not by being a minor |
| major | Own PR, labelled `major-update` for visibility | Same gate; the agent treats a major as `RISK: REVIEW`, so in practice **manual** |
| **databases / cache / SSO / edge build** (`postgres`, `mariadb`, `valkey`, `redis`, `goauthentik/server`, `immich-app/postgres`, `drizzelat/nas-caddy`) | Per stack | **Never swept** — `MERGE_SKIP_IMAGES` in the `window-merge` job holds them whatever the review graded; merge by hand. Labelled `needs-manual-review` so they stand out — a bad bump = data loss, full auth lockout or the whole edge down |
| **github-actions** (`actions/checkout` etc.) | Per action | **Automerged by Renovate itself**, any hour — no stack, no redeploy, a bad bump only breaks CI |
| **WebTunnel image inputs** (`stacks/a1-vps-webtunnel/Dockerfile`: the WebTunnel server version and the `golang` builder tag) | Per dependency | **Automerged by Renovate itself**, any hour — merging only rebuilds `webtunnel-bridge` on `main`; the digest PR that follows is reviewed and swept like any stack image. See [a1-vps-webtunnel.md → Image and security updates](services/a1-vps-webtunnel.md#image-and-security-updates) |
| **edge image inputs** (`stacks/caddy/Dockerfile`: both `caddy` base images, the xcaddy plugins, the `--replace` dependency overrides) | One grouped PR, `caddy image build` | **Swept** on its green "nothing to assess" status, without a Claude pass — merging only rebuilds `nas-caddy` on `main`; the digest PR that follows is held by `MERGE_SKIP_IMAGES` (row above). See [caddy.md → Upgrade](services/caddy.md#upgrade) |

- **No release-age soak** — PRs open immediately and get reviewed immediately; the next 05:00–06:00 window merges whatever came back clean. (`minimumReleaseAge`/`internalChecksFilter` removed — fast-releasing images kept resetting the soak clock and stranding PRs.)
- **Why authentik still stands out:** CalVer images (authentik `2026.M.P`, etc.) surface a month bump as a semver *minor* but carry DB migrations / breaking config. Since the mealie incident that is no longer a special case — *every* minor is judged on its release notes — but the label keeps these visible in the PR list.
- `vulnerabilityAlerts` + `osvVulnerabilityAlerts` are enabled; CVE-driven PRs get the `security` label.
- `prConcurrentLimit: 0` / `prHourlyLimit: 0` (unlimited).
- The window is now enforced by the sweep's own clock check (`TZ=Europe/Berlin`), not by `automergeSchedule` — that key is gone from the docker-compose rules along with Renovate's automerge.
- **Digest-only:** `ghcr.io/immich-app/postgres` — bespoke vendor tag (`18-vectorchordX.Y.Z`); its major/minor/patch updates are disabled (`enabled: false`), so Renovate only refreshes the digest. Bump the tag manually per immich release notes.
- Timezone `Europe/Berlin` (= Europe/Vienna offset). Merge → push → `deploy-stacks` → Komodo `DeployStack` ([deploy-stacks runbook](runbooks/setup-operations/deploy-stacks.md)).

#### Deploy safety nets (CI)

Two gates wrap the Renovate-merge → redeploy path so a bad image is caught instead of silently going live:

1. **Pre-merge — [`compose-validate.yml`](../.github/workflows/compose-validate.yml).** On every `pull_request` (no `paths:` filter — a path-filtered *required* check deadlocks PRs that don't touch those paths), runs `docker compose config -q` on each changed compose file (schema/syntax check); a PR that changes no compose file short-circuits to green in seconds. **Runs on a GitHub-hosted runner only** — never the self-hosted NAS runner (a `pull_request` job there would be RCE on the host; see [`stacks/github-runner`](../stacks/github-runner/docker-compose.yml)). It blocks automerge because its `validate` job is a **required status check** on the `main` branch protection. A second, **non-required** job in the same workflow (`docs-drift`, [`.github/scripts/docs-drift.py`](../.github/scripts/docs-drift.py)) enforces the doc promises from `AGENTS.md`: every stack has a `docs/services/<name>.md`, every LAN port it publishes appears in the `docs/network.md` ports table, every bind mount appears in the `docs/storage.md` mount table. Drift turns the run red for visibility but cannot wedge a merge. Run it locally with `python3 .github/scripts/docs-drift.py`.
2. **Post-deploy — [`deploy-stacks.yml`](../.github/workflows/deploy-stacks.yml).** After Komodo's `DeployStack` for each changed stack (creating a brand-new one first), it polls Komodo for that Stack's services (~4 min budget) and asserts each is `running` and, where a `healthcheck:` exists, `healthy`. On genuine failure it **auto-rolls-back**: restores that stack's files to their pre-push state, pushes to `main`, and deploys it again through Komodo; the run stays red for visibility. A freshly-created stack has nothing to roll back to and is only flagged.

**Required repo config for the post-deploy check:**

- secrets `KOMODO_DEPLOY_API_KEY` / `KOMODO_DEPLOY_API_SECRET` — the Komodo service user `deploy-stacks`: Execute plus Inspect on Stacks, Execute on the `komodo-resources` sync, nothing else ([komodo.md](services/komodo.md)).
- secret `ROLLBACK_TOKEN` — fine-grained PAT of a repo **admin** (`drizzelat/NAS` only, **Contents: read+write**). The auto-rollback push to `main` must clear branch protection; `GITHUB_TOKEN` isn't an admin so its push would be rejected by the required `validate` check. Unset → falls back to `GITHUB_TOKEN` and rollback pushes fail loud.
- Assumes the Komodo **Stack name == folder name == `project_name`**.

**Healthchecks.** The post-deploy gate is only as strong as each container's health state. Compose `healthcheck:` in: authentik (postgresql), downloads (gluetun), files, homarr, immich (pgvecto, redis), kuma, mealie (db/app), paperless (redis/db/web), romm (db/app), and off the NAS a1-vps-kuma and a1-vps-matrix (postgres). Image-provided healthchecks count too: gamevault-backend, shelfmark, geoipupdate. Deliberately none where the image has no shell or test binary (adguard, beszel = scratch), on the edge where a false-unhealthy would be high-blast-radius (caddy/crowdsec), or where the check is marginal (tailscale, github-runner). Those fall back to the "container running" assertion.

### FRITZ!Box firmware auto-update — daily 01:30 (FRITZ!Box UI)

Router-side, not TrueNAS. Set in *System → Update → AutoUpdate* to run at **01:30 Vienna**. A firmware install reboots the router → **WAN drops ~3–5 min**, which kills any WAN-dependent job in flight.

**Why 01:30.** It sits in the only quiet WAN gap: after the local-only jobs (snapshots/scrubs/SMART) but **before the 03:00 Cloud Sync chain**, with ~1.5 h buffer so a reboot fully settles first. Earlier incident: an overnight auto-update landed on top of the running cloud sync and failed the offsite backup. Avoid **03:00–07:00** (cloud sync runs open-ended, Renovate triggers 04:15/05:15, merge sweep 05:20–05:50, health check 06:30). The 15-min git-pull cron tolerates a reboot (retries next cycle). If cloud syncs ever run long enough to still be active at 01:30, move this window earlier.

### Periodic ZFS snapshot tasks

Standalone snapshot tasks, independent of the temporary snapshots that Cloud Sync takes before each push:

| Dataset | Schedule | Retention |
| --- | --- | --- |
| apps | every 4h (00:00, 04, 08, 12, 16, 20) | 3 days |
| data/smb_share | daily 01:00 | 14 days |
| data/immich | daily 01:00 | 14 days |
| data/paperless | daily 01:00 | 14 days |

`apps` is snapshotted frequently with short retention (config churns, small size); the bulk `data` leaves get one daily snapshot with longer retention. These run *before* the 02:30 dump / 03:00 sync window.

`data/mediaserver` (the bulk movie/TV library) has **no** snapshot task and is **not** cloud-synced — intentionally unprotected: it is large and re-acquirable, so local snapshots and offsite copies would cost space for little gain. Everything *about* the library that matters (Sonarr/Radarr/etc. config) lives under `apps/mediaserver/config/*`, which **is** snapshotted and synced.

### Disk health (S.M.A.R.T. + scrub)

- **S.M.A.R.T. tests** (UI tasks, `all_disks: true`): **SHORT** daily 02:00 on Mon–Fri + Sun; **LONG** Sat 02:00. So every day gets a short test except Saturday, which gets a long test.
- **NVMe is NOT covered by those UI tasks.** Despite `all_disks: true`, the middleware only dispatches S.M.A.R.T. tests to ATA/SCSI disks — `nvme0n1` is silently skipped. It was found (2026-07-29 health check) with only two self-test entries *ever*, at power-on hours 20 and 66, against 2,791 hours of runtime — ~113 days untested. That disk is the **entire `apps` pool and has no redundancy**, so [`scripts/nvme-smart-test.sh`](../scripts/nvme-smart-test.sh) runs its self-tests from TrueNAS cron on the same cadence, 5 min after the UI tasks (SHORT Mon–Fri + Sun 02:05, LONG Sat 02:05). Each run first mails the verdict of the *previous* test (a self-test is async — it is started by one run and judged by the next) and then starts a new one. The UI tasks are left as they are; they correctly cover sda/sdb/sdc.
- **Scrubs**: pool `data` every **Mon 00:00**, pool `apps` every **Tue 00:00**. Threshold 35 days (skips if a scrub ran within 35 days).

### Docker image prune — weekly Sun 04:30 (TrueNAS cron)

Cron id 8 runs `docker-image-prune.sh` (unused images older than 7 days), and a POSTINIT script
runs `docker-boot-guard.sh` at boot. The micro VPS and the A1 run the prune from a
`docker-image-prune.timer` (Sun 04:30 UTC). Until 2026-09-17 cron id 8 also ran
`portainer-image-guard.sh`, cron id 9 ran it hourly, and the POSTINIT script chained it after the
boot guard; all three went with Portainer. Details:
[docker-image-prune runbook](runbooks/setup-operations/docker-image-prune.md).

### Image CVE scan — weekly Mon 04:17 UTC (GitHub Actions)

[`image-cve-scan.yml`](../.github/workflows/image-cve-scan.yml) runs **Trivy** against every pinned `tag@sha256` across `stacks/` and surfaces fixable HIGH/CRITICAL CVEs *inside the image layers* — the coverage Renovate's `osvVulnerabilityAlerts` (package-version mapping) does not give. GitHub-hosted runner only (never the self-hosted NAS runner — it pulls arbitrary image contents). Non-blocking: writes a job summary and opens/updates a `security`-labelled tracking issue; does not gate deploys. `workflow_dispatch` for on-demand runs.

### Not scheduled (event-driven)

- **deploy-stacks / GitHub runner** — deploys fire on push, through Komodo. Not time-based, apart from Komodo's hourly `reconcile-owned` backstop (:23) and `deploy-runner`, which deploys a changed `github-runner` between jobs (:53). See [`docs/services/github-runner.md`](services/github-runner.md) and the [deploy-stacks runbook](runbooks/setup-operations/deploy-stacks.md).
- **Cloud Sync pre-push snapshots** — the template takes a temporary ZFS snapshot of its current `path` immediately before each push (separate from the periodic snapshot tasks above).
- **Parent whole-pool Cloud Sync tasks** — `App sync` (id 5) and `Data Sync` (id 6) are **disabled** (`snapshot: false`, so they never collide with the template); the template + chain do the work. Leave them disabled.
- **App-internal jobs** (immich ML/library scan, paperless consumer, adguard) run on each app's own defaults and are not configured in this repo.

## Verifying against the live host

SSH to the host (`ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111`) and query each task type (the runbooks run these as `sudo -n midclt …`):

```sh
midclt call cronjob.query '[]' '{"select":["description","command","schedule","enabled"]}'
midclt call cloudsync.query '[]' '{"select":["description","schedule","enabled","snapshot"]}'
midclt call pool.snapshottask.query '[]' '{"select":["dataset","schedule","enabled","lifetime_value","lifetime_unit"]}'
midclt call smart.test.query '[]' '{"select":["type","schedule","all_disks"]}'
midclt call pool.scrub.query '[]' '{"select":["pool_name","schedule","enabled","threshold"]}'
midclt call initshutdownscript.query '[]' '{"select":["when","command","enabled"]}'
midclt call rsynctask.query '[]'        # currently none
midclt call replication.query '[]'      # currently none
```
