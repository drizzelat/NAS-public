# Deploy-state probe

A deterministic, read-only assertion that **the running estate matches this repo**: every stack
deployed, on the host deploys route it to, on the digests the repo pins, healthy. It exits 0 or 1,
with no model in the loop.

The nightly [health check](nas-health-check.md) covers much of the same ground but cannot be this
gate: it runs once a day, costs tokens, and its verdict is a model's judgment rather than an exit
code.

- Workflow: [`.github/workflows/deploy-state-probe.yml`](../../../.github/workflows/deploy-state-probe.yml)
- Script: [`.github/scripts/deploy-state-probe.sh`](../../../.github/scripts/deploy-state-probe.sh)
- Trigger: [`scripts/deploy-state-trigger.sh`](../../../scripts/deploy-state-trigger.sh)

## What it asserts

| # | Check | FAIL when | Why it is here |
| --- | --- | --- | --- |
| 1 | Placement | a Komodo Server is missing or not `Ok`; a `stacks/` folder has no Komodo Stack, or a hand-applied one (the peripheries) has one; a Stack has no folder; a Stack is not `running` (`github-runner` may be `deploying`: its `pre_deploy` waits for the probe's own job to end, and the probe prints a `NOTE`); a Stack is on a different Server than its `[[stack]]` entry in [`komodo/resources.toml`](../../../komodo/resources.toml) declares (`komodo` itself: `nas`) | A stack that silently stopped being deployed looks fine from every other angle |
| 2 | Digests | any `DRIFT`, `NO SERVICE`, `NO REPO COMPOSE` or `ERROR` line from [`nas-health-image-drift.sh`](../../../.github/scripts/nas-health-image-drift.sh) | A running digest that is not the pin; a service removed from compose but still running (Komodo never passes `--remove-orphans`); a compose project no folder explains, which is what a deploy under the wrong project name looks like ([komodo.md → Rules](../../services/komodo.md#the-project-name-is-load-bearing)) |
| 3 | Health | any container, on any Komodo Server, that is neither running nor a clean `Exited (0)`, or is running `unhealthy` | The rule [`verify-healthy.sh`](../../../scripts/deploy/verify-healthy.sh) deploys by, applied to the whole estate instead of the stack just deployed |
| 4 | Networks | caddy is not attached to every `proxy_*` network `stacks/caddy/docker-compose.yml` defines | A `down` that removes one is unrecoverable without a from-scratch bring-up. The list is read from the compose file, never hard-coded |
| 5 | Host copies | a script installed outside the clone differs from the repo | `git-pull-nas.sh` keeps every host script current, and nothing deploys it ([nas-repo-autopull](nas-repo-autopull.md)) |
| 6 | Sync | the ResourceSync `komodo-resources` has pending changes more than 6 h after the last commit to [`komodo/resources.toml`](../../../komodo/resources.toml) (a `NOTE` before that), its pending view is still older than that commit 2 h after it, or it reports an error | `deploy-stacks` applies only a **new** `[[stack]]`; every other change waits for someone to read the diff and run the sync ([deploy-stacks](deploy-stacks.md)). Komodo refreshes the pending view itself (hourly, `KOMODO_RESOURCE_POLL_INTERVAL`), so the probe only reads. A change made in the UI shows as pending at once and fails the next run |
| 7 | Deterministic health checks | any FAIL from [`nas-deterministic-checks.sh`](../../../.github/scripts/nas-deterministic-checks.sh): snapshot recency or retention, scrub age, dump freshness/integrity **per labelled database** (not per dump directory — see below), cert expiry, the on-host clone, the boot-guard drop-in, Storage Box snapshots | Seven yes/no checks the nightly model run used to do. Here they cost nothing and run 4× a day instead of once |

Check 2 calls the nightly health check's own script unchanged and only turns its findings into an
exit code, so a fix to digest matching lands in both at once.

### Check 7: the thresholds, and where they come from

The script holds the cadences as constants at the top, each one the value documented in
[scheduled-tasks.md](../../scheduled-tasks.md) — snapshot cadence and retention per dataset and tier, the
35-day scrub threshold, the daily dump, plus the checklist's slack rule (cadence + 2 h, scrubs
+ 5 days). **Changing a schedule on the NAS means changing both**, the doc and the constant.
Cert expiry is judged against each certificate's own lifetime, not a fixed day count, because
short-lived certs would otherwise fail every night.

The Storage Box check needs a read-only Hetzner API token on the NAS
([backup.md → Watching the snapshots](../backup-restore/backup.md#watching-the-snapshots)). Without
it the check prints `SKIP`, so the probe stays green until the token exists.

The dump half expects one block **per database**, and builds the expected set by pairing each
`nas.backup.db` entry with its `nas.backup.dir` in `stacks/*/docker-compose.yml` — the same labels
`pg-dump-backup.sh` discovers. A labelled database that reports no `mtime` is a FAIL, which is
also what an out-of-date [`scripts/nas-health-probe.sh`](../../../scripts/nas-health-probe.sh) on
the NAS looks like: the probe emits the per-database blocks, so **a change to it has to be
installed on the host** ([nas-health-check → One-time setup](nas-health-check.md#one-time-setup)),
not just merged. Per database, not per directory: two databases can dump into one directory, and a
failed one hides behind a fresh sibling.

### No exceptions

Every untracked compose project is a `FAIL`. A scratch evaluation on an estate host needs its own
exception, here and in check 14 of [`.github/nas-health-check.md`](../../../.github/nas-health-check.md).

## Reading a run

The job log and the run summary carry one line per finding, then a `RESULT`:

```
PASS  placement: 30 stack folders match 30 Komodo Stacks, each running on its declared server
PASS  digests: 3 servers, 77 digest-pinned running containers: 0 drift, 0 no service, …
PASS  health: every container on 3 servers is running or cleanly Exited (0), none unhealthy
PASS  networks: caddy is attached to all 18 proxy_* networks its compose defines
PASS  host copies: 1 installed script(s) match the repo
PASS  sync: komodo-resources has no pending changes at 3959d67
RESULT  0 failure(s)
```

A `FAIL` names what to look at. A section whose API call failed reports that as its own `FAIL`
rather than passing unchecked.

**Proving a change to it can fail:** run it by hand ([below](#running-it-by-hand)) against the live
estate from a scratch checkout with one breakage each: an extra `stacks/` folder, a zeroed digest
pin, an extra `proxy_*` network in caddy's compose, a stack declared on the wrong Server, an edit to a
Procedure in the Komodo UI (check 6 goes red on the next run; undo it after). Each must
print its `FAIL` and exit non-zero.

## Where it runs, and why

The probe job runs on the **self-hosted NAS runner**, because Komodo Core is LAN-only. There is
exactly one runner and `deploy-stacks` runs on it too, so a probe cannot start while a deploy is
converging, and a deploy cannot start while a probe is reading.

Credentials:

- **`secrets.KOMODO_READ_API_KEY` / `KOMODO_READ_API_SECRET`:** the Komodo service user `probe-read`
  ([komodo.md](../../services/komodo.md)). It has Read on Servers, Stacks and the ResourceSync `komodo-resources`, plus Inspect on Servers,
  because Komodo's container list carries no labels. Inspect also shows every container's
  environment, so treat the key as a secret reader, not a harmless one. Every Komodo list call passes
  `"limit":0`: Komodo otherwise returns a page of 50 without saying so.
- **`secrets.NAS_HEALTH_SSH_KEY`:** the `nashealth` forced-command key, for the `yaml2json` and
  `host-copies` verbs.

When the NAS is down the probe cannot run at all. That is a NAS outage, not a probe failure; the
[edge access policy probe](edge-access-policy-probe.md) runs on `ubuntu-latest` and still fires.

## On-time trigger

Same pattern and same token as the
[edge access policy probe](edge-access-policy-probe.md#on-time-trigger): GitHub's `schedule:` drops
most slots, so a TrueNAS cron fires `workflow_dispatch` every 6 hours.

```
TrueNAS cron :47 at 03/09/15/21 Vienna ─▶ deploy-state-trigger.sh ─▶ POST /workflows/deploy-state-probe.yml/dispatches
GitHub cron 10:47 UTC                   ─▶ same workflow, fallback trigger only
```

The slots stay clear of the 05:00–06:00 Renovate merge window, the deploys it triggers, and the
06:30 health check, which shares the runner.

### The fallback, and why it is guarded

The **guard step** skips the scheduled run when a dispatched run already reached a conclusion that
UTC day, and otherwise runs it with a `::warning::` naming the broken cron — the edge probe's guard,
verbatim. Unlike the edge probe's, this fallback cannot help during a NAS outage, because the job
runs on the NAS runner.

The guard is a step, not its own `ubuntu-latest` job: a hosted job would bill a minute per run and
could be starved by an exhausted Actions quota. The whole workflow is self-hosted. `10:47` UTC is at
least two hours clear of every host slot in both DST offsets (01:47/07:47/13:47/19:47 UTC in summer,
an hour later in winter).

### Cron job (TrueNAS → System → Advanced → Cron Jobs, run as root)

| Schedule | Command |
| --- | --- |
| `47 3,9,15,21 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/deploy-state-trigger.sh` |

```sh
midclt call cronjob.create '{"description":"deploy-state-probe on-time trigger",
  "command":"/bin/sh /mnt/apps/scripts/nas/scripts/deploy-state-trigger.sh",
  "user":"root","schedule":{"minute":"47","hour":"3,9,15,21","dom":"*","month":"*","dow":"*"},
  "enabled":true,"stdout":true,"stderr":true}'
```

Prove the cron path, not only the script: `sudo midclt call -j cronjob.run <id>`, then
`tail -2 /var/log/deploy-state-trigger.log`. TrueNAS 25.04 writes nothing to `/etc/cron.d`, so
grepping for the entry proves nothing.

## Installing the probe verbs

Checks 5 and 7 need verbs in [`scripts/nas-health-probe.sh`](../../../scripts/nas-health-probe.sh),
which is installed **outside** the clone, so no pull updates it. Until it is re-installed, check 5
fails with `refused (unknown verb: host-copies)` and check 7 fails with the `storagebox` verb
missing, epoch-less snapshot times and dump directories reporting no `mtime` — each names the
re-install in its message. Re-install right after merging, with step 1 of the install block in
[nas-health-check.md](nas-health-check.md), which also installs
`scripts/nas-hetzner-snapshots.sh`.

## Running it by hand

From the repo root on a LAN machine, after `scripts/secrets.sh unlock`. `probe-read`'s key lives
only in the repo secrets, so a hand run uses the admin API key from the vault, which reads
everything `probe-read` can:

```sh
set -a
KOMODO_URL=https://komodo.example.com
KOMODO_RESOLVE=komodo.example.com:443:192.168.178.111
KOMODO_API_KEY=$(sed -n 's/^KOMODO_API_KEY=//p' secrets/stack-env/komodo.env)
KOMODO_API_SECRET=$(sed -n 's/^KOMODO_API_SECRET=//p' secrets/stack-env/komodo.env)
set +a
NAS_SSH_KEY_FILE=secrets/ssh/nas-health_ed25519 .github/scripts/deploy-state-probe.sh 192.168.178.111
```

Or dispatch it with `gh workflow run deploy-state-probe.yml`.
