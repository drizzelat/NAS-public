# Nightly Claude health check

Scheduled GitHub Actions job ([`nas-health-check.yml`](../../../.github/workflows/nas-health-check.yml))
that runs **Claude Code headless on the self-hosted runner** every night at
**06:30 Vienna**, dispatched by a host cron — see [On-time trigger](#on-time-trigger).
Claude follows the checklist in
[`.github/nas-health-check.md`](../../../.github/nas-health-check.md): SSH into the
host, read the Komodo API, work through 19 checks, and print a report
ending in `HEALTH: OK` or `HEALTH: FAIL`. Anything but `OK` turns the run red —
**GitHub's workflow-failure email is the alert**, same channel as
`deploy-stacks`. Green runs are silent.

| Group | Checks |
| --- | --- |
| Host | SSH reachability · TrueNAS `alert.list` · failed systemd units + NTP sync |
| Storage | pool health/capacity · SMART health + self-test results · scrub age · snapshot recency · snapshot **retention** (pruning still works) · storage drift (missing bind-mount paths = FAIL, orphan datasets = warning) |
| Backups | DB dumps: freshness **and** `gzip -t` + size sanity · cloud-sync chain last run (`fail=0`, not stale) |
| Repo vs live | auto-pull clone at repo `HEAD` · boot-guard drop-in matches its generator · deployed Komodo Stacks vs `stacks/` folders + running image digest vs the compose pin · Cloudflare IP ranges in the Caddyfile and the VPS `geo` block vs Cloudflare's published lists |
| Edge | Caddy access log, last 24 h: scanner paths, external `401`/`403` volume, and a real-client-IP canary on Kuma's own probes · CrowdSec decisions that did **not** come from the community blocklist. Needs `GRAFANA_TOKEN`, else SKIP |
| Services | container state on every Komodo Server · TLS cert expiry, judged against each cert's own lifetime rather than a flat day count (a short-lived certificate would fail a fixed floor nightly) |

Why an agent instead of a script: the dumb layers already exist (Kuma = uptime,
TrueNAS `smartd` + `nvme-smart-test.sh` = disks, Beszel = metrics, Kuma push
heartbeats on the backup jobs).
This check covers the *semantic* gaps — live state vs. repo truth (boot-guard
drop-in, auto-pull clone, deployed stacks and image digests), freshness
thresholds derived from [`scheduled-tasks.md`](../../scheduled-tasks.md), and a
written explanation when something is off instead of a bare red dot.

Several checks exist because the thing they watch fails **silently**: a fresh
but truncated dump passes a freshness check, the offsite cloud-sync chain only
emails on failure (so a chain that never ran is invisible), a `zpool` reads
`ONLINE` while a member disk accumulates reallocated sectors, and broken
snapshot pruning fills the 250 GB `apps` NVMe with nothing raising a hand.
Doc-vs-repo drift is *not* checked here — it can only change in a commit, so it
runs on pull requests instead ([`docs-drift.py`](../../../.github/scripts/docs-drift.py)).

## One-time setup (secrets)

| Secret | How |
| --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | On a machine with Claude Code logged in: `claude setup-token`, then `gh secret set CLAUDE_CODE_OAUTH_TOKEN` (paste). Uses the subscription. `ANTHROPIC_API_KEY` works instead (API billing). |
| `NAS_HEALTH_SSH_KEY` | `scripts/secrets.sh unlock`, then `gh secret set NAS_HEALTH_SSH_KEY < secrets/ssh/nas-health_ed25519`. **Not** `truenas_ed25519` — see [Host access](#host-access-the-nashealth-user) below. The vault key never reaches CI, so this is a workstation step. |
| `KOMODO_READ_API_KEY` / `KOMODO_READ_API_SECRET` | The Komodo service user `probe-read`, for `nas-health-image-drift.sh`. Already set (the deploy-state probe shares it); minted with `write/CreateApiKeyForServiceUser`, see [komodo.md](../../services/komodo.md). |
| `GRAFANA_TOKEN` | **Optional.** Grafana → Administration → Users and access → Service accounts → *New*, role **Viewer**, then *Add service account token* and `gh secret set GRAFANA_TOKEN`. Only reads through the datasource proxy; Viewer cannot edit dashboards or datasources. Without it the two Edge checks SKIP rather than fail. |

Optional repo
variable `CLAUDE_SESSION_TOKEN_BUDGET` overrides the assumed 5-hour session
budget used for the percentage below (default `1500000`).

`GRAFANA_TOKEN` needs no URL variable to go with it. `grafana.example.com` is LAN-only
in Caddy but still resolves **publicly** to Cloudflare, so a runner whose DNS is not
AdGuard would be sent to Cloudflare and then to the VPS, which drops the name — it is not
in the SNI allowlist. The checklist therefore derives the host and the NAS LAN IP from
`docs/network.md` and passes `--resolve`, the same way the certificate check already does.

## Host access: the `nashealth` user

The check reaches the NAS as **`nashealth`**, an unprivileged TrueNAS user whose
`authorized_keys` pins a forced command. It cannot get a shell, `scp`, forward a
port or allocate a PTY; every SSH invocation is matched against a fixed verb
list in [`scripts/nas-health-probe.sh`](../../../scripts/nas-health-probe.sh)
and anything else exits `111` having run nothing. The verb table the agent works
from is in [`.github/nas-health-check.md`](../../../.github/nas-health-check.md).

Until 2026-09-06 the job held `truenas_ed25519` — `truenas_admin`, `NOPASSWD:
ALL`, i.e. root on the NAS — to run a read-only report on the most frequently
scheduled job on the runner. That was
[SEC-1](../../architecture-review-2026-08-20.md#sec-1--github-account-compromise-equals-nas-root)
step 3. `NAS_SSH_KEY` stayed a repo secret for `deploy-portainer-app.yml`, which mutated the host.
Both were deleted on 2026-09-17 (SVC-2 Phase 3), so no CI job holds a `truenas_admin` key.

### What still needs root, and how little of it

Almost nothing does. `zfs`/`zpool` read fine as any user (`/dev/zfs` is `0666`),
the cloudsync log, the boot-guard drop-in, the dump dirs and the repo clone are
all world-readable, and `git` only needed `safe.directory` for the root-owned
clone. Two things are different:

- **SMART** needs raw device access. It is granted through
  [`scripts/nas-health-smart.sh`](../../../scripts/nas-health-smart.sh), which
  takes **no arguments** — it discovers devices with `smartctl --scan` itself.
  That is deliberate: a sudoers rule of the shape `smartctl -H -A /dev/*` matches
  arguments as one concatenated string, so the wildcard would span spaces and
  accept far more than a device name. A no-argument helper has nothing to inject.
- **`midclt`** authenticates over the middleware socket as the calling user and
  applies that user's privilege allowlist, so an unprivileged user gets nothing.
  Four exact calls are granted instead.

The grants live on the user, not in a file:

```text
nashealth ALL=(ALL) NOPASSWD: /mnt/apps/scripts/nas-health-smart.sh,
  /usr/bin/midclt call alert.list, /usr/bin/midclt call disk.query,
  /usr/bin/midclt call cloudsync.query
```

sudoers matches the full argv, so `midclt call user.query` is not reachable from
`midclt call alert.list`. The alternative — dropping `nashealth` into
`truenas_readonly_administrators` (the builtin `READONLY_ADMIN` role) — was
rejected: it would grant read of the *entire* middleware API for the sake of four
calls.

> **`cloudsync.query` returns the repository's `encryption_password` and
> `encryption_salt` in plaintext.** The probe projects the response down to
> `state`/`time_finished`/`schedule` before it leaves the host. Keep that filter
> if you touch the `cloudsync` verb.

### What survives a TrueNAS update (the part that bites)

TrueNAS SCALE boots a **boot environment** — `boot-pool/ROOT/<version>` — and an
update creates a *new* one from the update image. `/` and `/usr` are mounted
**read-only**, `/home` is mounted **`noexec`**, and `/etc`, while writable, is
part of the same boot environment. So:

| Put it here | Survives an update? |
| --- | --- |
| `/usr/local/bin/…` | **No** — and it is read-only, you cannot install there at all |
| `/etc/sudoers.d/…` | **No** — new boot environment, and `/etc/sudoers` is regenerated anyway |
| `/home/<user>/.ssh/…` | **No** — and `noexec` besides |
| the TrueNAS config DB | **Yes** — and it is in the config backup |
| a data pool (`/mnt/apps/…`) | **Yes** |

That is why nothing here is placed by hand in the base OS:

- **The user** is created with `midclt call user.create`, so uid, shell, home and
  the sudo grants live in the config DB. `/etc/sudoers` is *generated* from that
  DB on every boot by middleware's `local/sudoers` template — a hand-written
  `/etc/sudoers.d/` file would be silently dropped by the next update, and a
  `useradd` user would vanish with it.
- **Both scripts** live in `/mnt/apps/scripts/`, on the `apps` pool, beside
  `git-pull-nas.sh` — which is out-of-band in the same place for the same reason
  ([nas-repo-autopull](nas-repo-autopull.md)).
- **The home directory** is `/mnt/apps/nas-health`, not `/home/nashealth`.

> **The SSH key is the one thing not in the config DB.** `sshpubkey` has no
> column in `account_bsdusers`; `user.query` reads it back out of the user's
> `~/.ssh/authorized_keys`, and `user.create` writes it there. TrueNAS enforces
> the consequence itself — it refuses `sshpubkey` outright unless `home` is under
> `/mnt`. So the forced-command line exists **only as a file on the `apps` pool**
> and is **not** in a TrueNAS config backup. Restoring a config onto a fresh boot
> environment brings the user and its sudo grants back but leaves it with no key:
> re-run step 3 below from the vault.

### One-time setup

Run from a workstation with the vault unlocked (`scripts/secrets.sh unlock`).

```sh
NAS=truenas_admin@192.168.178.111; KEY=secrets/ssh/truenas_ed25519

# 1. Install both scripts on the data pool, root-owned so nashealth cannot edit them.
scp -i "$KEY" scripts/nas-health-probe.sh scripts/nas-health-smart.sh "$NAS:/tmp/"
ssh -i "$KEY" "$NAS" 'sudo -n install -m 755 -o root -g root \
  /tmp/nas-health-probe.sh /tmp/nas-health-smart.sh /mnt/apps/scripts/ &&
  rm -f /tmp/nas-health-probe.sh /tmp/nas-health-smart.sh'

# 2. Home directory. Must be under /mnt or TrueNAS refuses to store an SSH key.
ssh -i "$KEY" "$NAS" 'sudo -n install -d -m 755 -o root -g root /mnt/apps/nas-health'

# 3. The user, via middleware so it lands in the config DB. The sshpubkey field
#    takes the whole authorized_keys line, forced command included.
python3 - <<'EOF' > /tmp/nashealth.json
import json
pub = open('secrets/ssh/nas-health_ed25519.pub').read().strip()
print(json.dumps({
  "uid": 3003, "username": "nashealth",
  "full_name": "nas-health-check CI (forced command, read-only)",
  "home": "/mnt/apps/nas-health", "home_create": False,
  "shell": "/usr/bin/dash", "group_create": True,
  "password_disabled": True, "ssh_password_enabled": False, "smb": False,
  "sshpubkey": 'command="/mnt/apps/scripts/nas-health-probe.sh",restrict ' + pub,
  "sudo_commands": [],
  "sudo_commands_nopasswd": [
    "/mnt/apps/scripts/nas-health-smart.sh",
    "/usr/bin/midclt call alert.list",
    "/usr/bin/midclt call disk.query",
    "/usr/bin/midclt call cloudsync.query",
  ],
}))
EOF
scp -i "$KEY" /tmp/nashealth.json "$NAS:/tmp/"
ssh -i "$KEY" "$NAS" 'midclt call user.create "$(cat /tmp/nashealth.json)"; rm -f /tmp/nashealth.json'
rm -f /tmp/nashealth.json

# 4. Take the home dir back off the user: it cannot then rewrite its own key.
ssh -i "$KEY" "$NAS" 'sudo -n chown -R root:root /mnt/apps/nas-health &&
  sudo -n chmod 755 /mnt/apps/nas-health /mnt/apps/nas-health/.ssh &&
  sudo -n chmod 644 /mnt/apps/nas-health/.ssh/authorized_keys'
```

`restrict` is `no-port-forwarding` + `no-agent-forwarding` + `no-X11-forwarding`
+ `no-pty` + `no-user-rc`, and picks up whatever OpenSSH adds later; `command=`
overrides whatever the client asks for. The shell must be a real one
(`/usr/bin/dash`) — the forced command runs *through* it.

### Verifying the fence

```sh
K=secrets/ssh/nas-health_ed25519; H=nashealth@192.168.178.111

ssh -i $K $H 'help'                  # the verb list
ssh -i $K $H 'version'               # must match sha256sum scripts/nas-health-*.sh
ssh -i $K $H 'host'                  # a real check

ssh -i $K $H 'id'                    # refused (unknown verb: id), exit 111
ssh -i $K $H 'sudo -n midclt call user.query'   # refused (unknown verb: sudo)
ssh -i $K $H 'paths /etc/shadow'     # refused (path is not under /mnt)
ssh -i $K $H                         # refused (no command) — no shell
scp -i $K $H:/etc/shadow /tmp/x      # scp: Connection closed
ssh -i $K -o ExitOnForwardFailure=yes -R 19998:127.0.0.1:22 -N $H   # forwarding failed
```

**Re-install both scripts after every change to them in this repo.** `version`
prints the `sha256` of the installed copies; compare with
`sha256sum scripts/nas-health-probe.sh scripts/nas-health-smart.sh`. A verb the
checklist names but the host does not have makes those checks SKIP, not FAIL.

The probe also serves [`deploy-state-probe`](deploy-state-probe.md)'s `host-copies` verb, and that
workflow has no SKIP: a re-install that lags this repo turns every one of its runs red within six
hours, not only tonight's health check.

### Rotating the key

`user.update` will not carry a new `sshpubkey` here — middleware only allows that
when the home directory is a dataset mountpoint, and `/mnt/apps/nas-health` is a
plain directory on the `apps` dataset. Write the file instead:

```sh
ssh-keygen -t ed25519 -N '' -f secrets/ssh/nas-health_ed25519 \
  -C 'nas-health-check CI -> nashealth@truenas (forced command)'
printf 'command="/mnt/apps/scripts/nas-health-probe.sh",restrict %s\n' \
  "$(cat secrets/ssh/nas-health_ed25519.pub)" > /tmp/ak
scp -i secrets/ssh/truenas_ed25519 /tmp/ak truenas_admin@192.168.178.111:/tmp/
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111 \
  'sudo -n install -m 644 -o root -g root /tmp/ak /mnt/apps/nas-health/.ssh/authorized_keys && rm /tmp/ak'
rm /tmp/ak
scripts/secrets.sh lock          # commit only secrets.enc/ssh/nas-health_ed25519*.age
gh secret set NAS_HEALTH_SSH_KEY < secrets/ssh/nas-health_ed25519
```

### After a TrueNAS update

The user, its sudo grants and both scripts are all outside the boot environment,
so an update should change nothing. Confirm it did not anyway — it is one
command, and a silent loss of access shows up as a red run at 06:30:

```sh
ssh -i secrets/ssh/nas-health_ed25519 nashealth@192.168.178.111 'version'
```

## On-time trigger

GitHub's `schedule:` cron is **best-effort**, and for this repo it has stopped
being usable: measured over 2026-08/09 the delivery delay ran **2.5–5.5 h** at
every slot, and `renovate.yml`'s hourly cron collapsed from 24 runs/day to 2–5
from 2026-08-27 on. A 04:30 UTC check was landing at 09:30 UTC, so an overnight
backup failure sat unreported until midday.

That matters more here than for a late merge: the checklist grades **time-relative**
thresholds — snapshot recency (4 h + 2 h), same-day dump freshness, the cloud-sync
chain against 03:00 + 2 h. It is also meant to run *after* the 05:20–05:50 merge
sweep, so check 14 compares the repo against stacks that have finished deploying.

So the primary trigger is a TrueNAS cron hitting `workflow_dispatch`, the same
pattern (and the same token) as the [Renovate on-time trigger](renovate-trigger.md):

```
TrueNAS cron 06:30 Vienna ─▶ nas-health-trigger.sh ─▶ POST /workflows/nas-health-check.yml/dispatches
GitHub cron 06:30 UTC     ─▶ same workflow, fallback trigger only
```

The host clock is Europe/Vienna, so the cron follows DST on its own; no UTC
summer/winter pair.

### The fallback, and why it is guarded

The GitHub `schedule:` block stays, but it is **not** a NAS-down fallback — the
runner lives *in* the NAS, in the runner VM ([`stacks/github-runner`](../../../stacks/github-runner/docker-compose.yml),
label `nas`), so if the NAS is down neither trigger produces a run. Total NAS
outage is covered by the [external heartbeat](external-heartbeat.md) instead.
What it does cover is the host cron silently breaking while the NAS is up —
otherwise a dead trigger looks exactly like a run of quiet, healthy nights.

A run costs ~$1.70 and ~half a 5-hour Pro session, so the fallback must not
duplicate the dispatch. The workflow's first step checks its own run list and
exits early when a `workflow_dispatch` run already reached a conclusion on the
same UTC day; when none did, it runs **and** logs a `::warning::` naming the
broken cron. It needs `actions: read`, which is why the workflow grants it.

Its cron is 06:30 **UTC** — two hours behind the host cron even in winter
(06:30 Vienna = 05:30 UTC), so the guard never races the run it is checking for.

### Cron job (TrueNAS → System → Advanced → Cron Jobs, run as root)

| Schedule | Command |
| --- | --- |
| `30 6 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/nas-health-trigger.sh` |

Same conventions as the Renovate crons: `user: root`, `enabled: true`, stdout and
stderr suppressed (the script logs to `/var/log/nas-health-trigger.log`), invoked
via `/bin/sh <path>` because the repo is authored on Windows and the exec bit does
not survive. Create it from the shell if you prefer the UI:

```sh
midclt call cronjob.create '{"description":"nas-health-check on-time trigger",
  "command":"/bin/sh /mnt/apps/scripts/nas/scripts/nas-health-trigger.sh",
  "user":"root","schedule":{"minute":"30","hour":"6","dom":"*","month":"*","dow":"*"},
  "enabled":true,"stdout":true,"stderr":true}'
```

The token is the existing fine-grained PAT at `/root/.config/renovate-trigger.token`
(**Actions: read+write** on `drizzelat/NAS` only) — already on the host for the
Renovate crons, no new secret. Setup and rotation:
[Renovate on-time trigger](renovate-trigger.md).

Verify a dispatch by hand:

```sh
sudo /bin/sh /mnt/apps/scripts/nas/scripts/nas-health-trigger.sh
tail -2 /var/log/nas-health-trigger.log
```

## Operations

- **Manual run:** Actions → `nas-health-check` → *Run workflow* (or
  `gh workflow run nas-health-check`). Report lands in the job summary.
- **Change what's checked:** edit `.github/nas-health-check.md` — the checks and
  their pass criteria live there, not in the workflow. Keep the hard read-only
  rules and the `HEALTH:` verdict contract intact.
- **Model/cost:** pinned to `claude-sonnet-5` in the workflow — one agentic run
  per night against the subscription/API. Token usage, turn count, cost and the
  share of a 5-hour Claude Pro session the run consumed are printed in the job
  log and summary (**Tokens:** line). Job timeout is 45 min.
- **Where the cost actually is.** On the 2026-09-07 baseline (48.9% of a session)
  the weighted split was cache-read 46%, output 28%, cache-write 26% — i.e. it is
  driven by *turn count × context size*, not by the checklist, which is only ~8%
  of the ~61k context each turn re-reads. So the levers are the **Cost** and
  **Style** sections of [`.github/nas-health-check.md`](../../../.github/nas-health-check.md):
  batch verbs into one `ssh`, filter tool output at the source rather than pulling
  whole listings into context, never re-fetch, and keep the report terse (output
  is weighted 5x). Compressing the checklist prose itself buys almost nothing.
  Watch the Tokens line after adding checks.
- **Per-turn meter.** Every run uploads a `nas-health-meter` artifact (kept 14 days):
  `meter.tsv`, one row per model turn — context re-read, cache writes, a rough thinking-token
  estimate, tool-result size and the tool call — plus the raw `claude.jsonl` stream it is
  built from. Read it before deciding which checks to move out of the agent:
  `gh run download <run-id> -n nas-health-meter && column -t -s $'\t' meter.tsv`.
  [`claude-turn-meter.jq`](../../../.github/scripts/claude-turn-meter.jq) rebuilds the table
  from any saved stream. Real output tokens stay a run total on the Tokens line — the stream
  only carries each turn's start-of-message snapshot. The raw stream is **not** secret-masked
  the way the job log is; acceptable only while the repo stays private.
- **What the first meter showed (2026-09-10, 76% of a session).** The biggest avoidable
  cost was orientation, not the checks: whole-file reads of `scheduled-tasks.md`,
  `network.md` and `storage.md` that every later turn re-read; the agent following the
  repo `CLAUDE.md` into `AGENTS.md` and an empty memory directory; and a shallow checkout
  that broke check 14's `git log -S` until the agent unshallowed it by hand. Hence the
  section greps in the checklist's **Cost** section, the prompt's "self-contained" line, and
  `fetch-depth: 0` on the checkout.
- **What the second meter showed (2026-09-11, 39% after those fixes).** The largest results
  left were two mechanical gathers. Check 14 listed every compose pin and every container
  (20.7k chars), then compared `.Image` strings instead of `RepoDigests`. Check 5 spooled
  the ~16 KB `smart` output and read it back in ranges. Both now run through runner-side
  helpers that print only what the check judges, so the probe needs no re-install:
  [`nas-health-image-drift.sh`](../../../.github/scripts/nas-health-image-drift.sh)
  (findings plus a `SUMMARY` line, under 1k chars on a clean night) and
  [`nas-health-smart-summary.awk`](../../../.github/scripts/nas-health-smart-summary.awk)
  (~2.3k chars).
- **The session percentage is an estimate.** Anthropic states the Pro 5-hour
  limit in prompts, not tokens, and the CLI's JSON carries no limit data. The
  workflow converts the run to input-token equivalents (cache-write ×1.25,
  cache-read ×0.1, output ×5 — Sonnet's prices relative to an input token) and
  divides by a 1.5M budget, roughly the ~40 Sonnet prompts a Pro window allows.
  Tune it with `CLAUDE_SESSION_TOKEN_BUDGET`; the same formula and default live
  in [`renovate-pr-review`](renovate-pr-review.md), so change both together.
- **Adding a check that needs new host data** means adding a verb to
  [`scripts/nas-health-probe.sh`](../../../scripts/nas-health-probe.sh) and
  re-installing it — the agent cannot run an arbitrary command any more. Add the
  verb to `VERBS`, to `usage()`, to the `case`, and to the verb table in
  `.github/nas-health-check.md`.
- **No hardcoded facts:** the checklist names repo sources (`scheduled-tasks.md`,
  `pg-dump-backup.sh`, `network.md`, …) instead of concrete datasets/dirs/hosts —
  the agent re-derives them each run, so new services/dumps/snapshot tasks are
  covered automatically once documented in the repo.

## Caveats

- Runs on the runner: if the runner (or the whole NAS) is down, the run never
  starts — the job sits queued and eventually fails, and the A1 Kuma and
  [healthchecks.io](external-heartbeat.md) are the layers that catch a dead NAS.
- GitHub `schedule:` is best-effort and mostly dropped for this repo, which is why
  the host cron is the primary trigger (see [On-time trigger](#on-time-trigger)).
- GitHub disables cron workflows after ~60 days without repo activity — not a
  concern while Renovate commits daily, but re-enable it if the repo ever goes
  quiet.
- The agent's SSH key is *enforced* read-only by the forced command, not merely
  instructed — a workflow that lands on `main` can no longer reach the host
  through it. The job carries no write-scoped Git/rollback credentials either.
  Until 2026-09-17 it also held `PORTAINER_API_TOKEN`, which is write-scoped
  ([SEC-3](../../architecture-review-2026-08-20.md#sec-3--portainer-token-scope-claims-are-wrong)).
  It now reads through the Komodo service user `probe-read`: Read plus Inspect, no Execute,
  no Write. Inspect still shows container environments, so the checklist pipes
  `InspectContainer` straight into `jq` ([komodo.md](../../services/komodo.md)).

## Last updated

2026-09-11
