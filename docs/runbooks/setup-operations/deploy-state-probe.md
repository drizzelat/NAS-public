# Deploy-state probe

A deterministic, read-only assertion that **the running estate matches this repo**: every stack
deployed, on the host deploys route it to, on the digests the repo pins, healthy. It exits 0 or 1,
with no model in the loop.

It is the acceptance test
[komodo-migration.md §1](komodo-migration.md#1-the-acceptance-test-does-not-exist-and-that-is-the-first-work-item)
asked for: green against Portainer first, green for a week **before Komodo exists**, then the gate
after every single adoption in §9. The nightly [health check](nas-health-check.md) covers much of
the same ground but cannot be that gate: it runs once a day, costs tokens, and its verdict is a
model's judgment rather than an exit code.

- Workflow: [`.github/workflows/deploy-state-probe.yml`](../../../.github/workflows/deploy-state-probe.yml)
- Script: [`.github/scripts/deploy-state-probe.sh`](../../../.github/scripts/deploy-state-probe.sh)
- Trigger: [`scripts/deploy-state-trigger.sh`](../../../scripts/deploy-state-trigger.sh)

## What it asserts

| # | Check | FAIL when | Why it is here |
| --- | --- | --- | --- |
| 1 | Placement | a Komodo Server is missing or not `Ok`; a `stacks/` folder has no Komodo Stack, or a hand-applied one (the peripheries) has one; a Stack has no folder; a Stack is not `running` (`github-runner` may be `deploying`: its `pre_deploy` waits for the probe's own job to end, and the probe prints a `NOTE`); a Stack is on a different Server than its `[[stack]]` entry in [`komodo/resources.toml`](../../../komodo/resources.toml) declares (`komodo` itself: `nas`) | A stack that silently stopped being deployed is the failure GAP-1 described, and a migration moves every stack |
| 2 | Digests | any `DRIFT`, `NO SERVICE`, `NO REPO COMPOSE` or `ERROR` line from [`nas-health-image-drift.sh`](../../../.github/scripts/nas-health-image-drift.sh) | A running digest that is not the pin; a service removed from compose but still running (Komodo never passes `--remove-orphans`, F15); a compose project no folder explains, which is what an adoption under the wrong project name looks like (F13) |
| 3 | Health | any container, on any Komodo Server, that is neither running nor a clean `Exited (0)`, or is running `unhealthy` | The rule [`verify-healthy.sh`](../../../scripts/deploy/verify-healthy.sh) deploys by, applied to the whole estate instead of the stack just deployed |
| 4 | Networks | caddy is not attached to every `proxy_*` network `stacks/caddy/docker-compose.yml` defines | A `down` that removes one is unrecoverable without a from-scratch bring-up (SVC-1 F2). The list is read from the compose file, never hard-coded |
| 5 | Host copies | a script installed outside the clone differs from the repo | `git-pull-nas.sh` delivers every Caddyfile change, and nothing deploys it (F11) |

Check 2 calls the nightly health check's own script unchanged and only turns its findings into an
exit code, so a fix to digest matching lands in both at once.

### No exceptions

Until 2026-09-15 the Komodo Phase 0 evaluation's two A1 projects, `komodo-core-eval` and
`komodo-periphery-eval`, were a `NOTE` while [komodo-migration.md](komodo-migration.md) still listed
items to measure. The eval was torn down when that line merged (#353), and the exception went with
it: every untracked compose project is a `FAIL`. A future scratch evaluation needs its own exception,
here and in check 14 of [`.github/nas-health-check.md`](../../../.github/nas-health-check.md).

## Reading a run

The job log and the run summary carry one line per finding, then a `RESULT`:

```
PASS  placement: 30 stack folders match 30 Komodo Stacks, each running on its declared server
PASS  digests: 3 servers, 77 digest-pinned running containers: 0 drift, 0 no service, …
PASS  health: every container on 3 servers is running or cleanly Exited (0), none unhealthy
PASS  networks: caddy is attached to all 18 proxy_* networks its compose defines
PASS  host copies: 1 installed script(s) match the repo
RESULT  0 failure(s)
```

A `FAIL` names what to look at. A section whose API call failed reports that as its own `FAIL`
rather than passing unchecked.

**Proved able to fail, not only to pass.** On 2026-09-11, against the live estate with breakages
made in a scratch checkout only, each of these produced its `FAIL` and a non-zero exit: an extra
`stacks/` folder, a zeroed digest pin, the eval marker removed, an extra `proxy_*` network in
caddy's compose, and the not-yet-installed `host-copies` verb.

**Moved from Portainer to Komodo on 2026-09-17** (komodo-migration.md §8 Phase 3, PR 4), and proved
the same way:

- **Side by side:** both backends ran from the workstation against the live estate. Both found 77
  digest-pinned containers on 3 hosts, and every check was a PASS. The only difference: placement
  counts 30 Stacks, not 29, because `komodo` itself is a Komodo Stack.
- **An orphan:** a scratch container labelled as an extra `homarr` service made both backends print
  the same `NO SERVICE` FAIL.
- **Placement, in a scratch copy of the tree:** an extra `stacks/` folder, and `homarr` declared on
  the wrong Server, each produced its FAIL.

## Where it runs, and why

The probe job runs on the **self-hosted NAS runner**, because Komodo Core is LAN-only. There is
exactly one runner and `deploy-stacks` runs on it too, so a probe cannot start while a deploy is
converging, and a deploy cannot start while a probe is reading.

Credentials:

- **`secrets.KOMODO_READ_API_KEY` / `KOMODO_READ_API_SECRET`:** the Komodo service user `probe-read`
  ([komodo.md](../../services/komodo.md)). It has Read on Servers and Stacks, plus Inspect on Servers,
  because Komodo's container list carries no labels. Inspect also shows every container's
  environment, so treat the key as a secret reader, not a harmless one. Every Komodo list call passes
  `"limit":0`: Komodo otherwise returns a page of 50 without saying so (komodo-migration.md F32).
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

The `guard` job, on `ubuntu-latest`, skips the scheduled run when a dispatched run already reached a
conclusion that UTC day, and otherwise runs it with a `::warning::` naming the broken cron — the
edge probe's guard, verbatim. Unlike the edge probe's, this fallback cannot help during a NAS
outage, because its probe job needs the NAS runner. `10:47` UTC is at least two hours clear of every
host slot in both DST offsets (01:47/07:47/13:47/19:47 UTC in summer, an hour later in winter).

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

## Installing the `host-copies` verb

Check 6 needs a verb in [`scripts/nas-health-probe.sh`](../../../scripts/nas-health-probe.sh), which
is installed **outside** the clone. Until it is re-installed, every run fails check 5 with
`refused (unknown verb: host-copies)`, and the nightly health check flags the probe's own `version`
drift. Re-install it right after merging, with step 1 of the install block in
[nas-health-check.md](nas-health-check.md).

## Running it by hand

From the repo root on a LAN machine, after `scripts/secrets.sh unlock`. `probe-read`'s key lives
only in the repo secrets, so a hand run uses the admin API key from the vault, which reads
everything `probe-read` can:

```sh
set -a
KOMODO_URL=https://komodo.example.com
KOMODO_RESOLVE=komodo.example.com:443:192.168.178.111
KOMODO_API_KEY=$(sed -n 's/^KOMODO_API_KEY=//p' secrets/portainer-env/komodo.env)
KOMODO_API_SECRET=$(sed -n 's/^KOMODO_API_SECRET=//p' secrets/portainer-env/komodo.env)
set +a
NAS_SSH_KEY_FILE=secrets/ssh/nas-health_ed25519 .github/scripts/deploy-state-probe.sh 192.168.178.111
```

Or dispatch it with `gh workflow run deploy-state-probe.yml`, which is what §9 of the Komodo plan
does after every adoption.

## The soak

Komodo is not installed on the estate until this workflow has been **green for 7 days**, counted
from its first green dispatched run on `main`. That is gate 6 in
[komodo-migration.md §0](komodo-migration.md#start-gate).
