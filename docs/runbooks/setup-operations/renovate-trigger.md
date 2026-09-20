# Runbook: Renovate on-time trigger (host cron → workflow_dispatch)

## Why

The self-hosted Renovate GitHub Action ([`renovate.yml`](../../../.github/workflows/renovate.yml))
was driven only by GitHub Actions `schedule:` cron. That cron is **best-effort**:
GitHub queues scheduled workflows and runs them late (heaviest delay at the top of
the hour) or drops them. Observed 2026-07: scheduled runs fired **08:05–09:34
Vienna** instead of on the hour.

That is not cosmetic. [`renovate.json`](../../../renovate.json) has **no**
`schedule` window — every run opens/refreshes PRs — and back when Renovate also
did the merging, only a run landing inside `automergeSchedule` (05:00–06:00)
merged anything. A delayed cron meant nothing merged that morning.

> **Since 2026-07-29 Renovate no longer merges stack PRs** (`automerge: false`
> for `docker-compose`). [`renovate-pr-review.yml`](../../../.github/workflows/renovate-pr-review.yml)
> reviews every stack PR and its own `window-merge` sweep does the merging inside
> 05:00–06:00 Berlin — see the [PR review runbook](renovate-pr-review.md). This
> cron therefore no longer controls *merging*; it controls **whether fresh PRs
> exist and are reviewed by the time the sweep runs**, and it is still what
> merges `github-actions` bumps (the one thing Renovate still automerges).

## Fix

Trigger the workflow through the REST **`workflow_dispatch`** endpoint from a
TrueNAS cron. A dispatch event runs promptly — it does **not** go through the
delayed `schedule` queue — so we pick the minute the run starts.
[`scripts/renovate-trigger.sh`](../../../scripts/renovate-trigger.sh) does the POST.

| Host cron (Europe/Vienna) | Lands in | Renovate does |
| --- | --- | --- |
| `15 4 * * *` | an hour before the merge window | opens/refreshes PRs, so their reviews have finished by the time the sweep runs |
| `15 5 * * *` | 05:00–06:00 window | same, plus merges **one** eligible `github-actions` PR per run. Stack PRs are merged by the review workflow's sweep, not here |

The **host clock is Europe/Vienna**, so these crons follow DST automatically —
no UTC / summer-winter cron pair like the GitHub `schedule:` block needs.

### Why two dispatches and not twelve

The original design was `*/5 5 * * *` — twelve dispatches across the window —
because **Renovate automerges at most one PR per run.** After a merge it logs
`Restarting repository job after automerge result`, re-extracts, and does not
merge again in that run. A single 05:15 dispatch therefore drained exactly **one
PR per day** — always the daily-recreated `stacks/github-runner` digest PR — while
every other stack PR queued indefinitely (observed 2026-07-29: 14 open, all green).

**That rationale expired** when stack merges moved to
[`renovate-pr-review.yml`](renovate-pr-review.md)'s sweep, which merges *every*
cleared PR in one pass. Renovate's one-per-run limit now only applies to
`github-actions` bumps, of which there is rarely more than one a day. So these
crons exist purely to make sure fresh PRs are **open and reviewed** before the
sweep runs at 05:20 — one pass an hour early and one in-window is enough.
These two dispatches are now the **only** triggers: the hourly `schedule:` was
removed on 2026-09-18 (see below).

If `github-actions` PRs ever pile up, the lever is more dispatches: each run
takes ~2 min and `renovate.yml` declares `concurrency: renovate` with
`cancel-in-progress: false`, so overlapping dispatches queue instead of racing.

This pairs with **`"rebaseWhen": "conflicted"`** in `renovate.json`. With
`automerge` on, Renovate's default (`auto`) rebases every open branch the moment
`main` moves — so each merge pushed a fresh commit onto all remaining branches and
reset their check-runs to pending, making them unmergeable for the rest of the
window. Branch protection on `main` has `strict: false` (up-to-date branches are
**not** required), so that rebase bought nothing but CI churn. Real conflicts still
rebase; stacks live in separate folders so those are rare.

**The hourly `schedule:` cron was removed on 2026-09-18.** It was kept as a
fallback — opening PRs through the day, and firing (late) if the NAS was down at
05–06 Vienna. Two things ended that. GitHub throttled scheduled events from
2026-08-27: they land 2.5–5.5 h late and are mostly dropped, so the fallback no
longer fires when it is needed. And at ~3 billed minutes a run it was the
second-largest line on the Actions bill for a trigger that had stopped working.

**What this costs:** PRs now open only at 04:15 and 05:15 Vienna, not through the
day, and a NAS offline at 05–06 Vienna means no Renovate that day. Neither blocks
anything — the next day's dispatch picks the backlog up, and the sweep merges every
cleared PR in one pass. If you want an off-NAS fallback back, use a dispatch from
somewhere that is not the NAS rather than restoring `schedule:`.

> The 04:15 cron originally targeted a 04:00–05:00 `schedule` open-window in
> renovate.json. That window was removed (every run opens PRs now) and this
> runbook once called the cron redundant — it is **not**, since the sweep moved
> to 05:20: a 04:15 pass gives every fresh PR an hour for its review to finish,
> so the morning's bumps can merge the same morning instead of the next one.

```text
TrueNAS cron 04:15 + 05:15 Vienna ─▶ renovate-trigger.sh ─▶ POST /workflows/renovate.yml/dispatches
                                                                      │  (prompt, not the schedule queue)
                                                                      ▼
                                                     Renovate run ─▶ opens/refreshes stack PRs
                                                                  ─▶ merges ONE github-actions PR, then restarts
                                                                  ─▶ each new PR triggers its review
                                                                        └─▶ renovate-review status (green = cleared)

TrueNAS cron 05:20/05:35/05:50 Vienna ─▶ merge-sweep-trigger.sh ─▶ POST /workflows/renovate-pr-review.yml/dispatches
GitHub cron every 10 min of 03+04 UTC ─▶ same workflow, fallback trigger only
                                                                      ▼
                                                     `window-merge` ─▶ merges EVERY cleared stack PR (05:xx Berlin only)
                                                                    ─▶ each merge ─▶ deploy-stacks ─▶ Komodo DeployStack
```

## Auth (dedicated fine-grained PAT)

`workflow_dispatch` needs a token with **Actions: read and write** on this repo.
That is far less than the Renovate App installation token the run itself mints (see
[Renovate as a GitHub App](renovate-github-app.md)).
Mint a **separate, minimal** token so the host copy can't do more than fire runs:

1. GitHub → *Settings → Developer settings → Fine-grained tokens → Generate new*.
2. Resource owner `drizzelat`, **only** repository `drizzelat/NAS`.
3. Repository permissions → **Actions: Read and write**. Nothing else.
4. Store it on the host, root-only:

   ```sh
   sudo install -d -m 700 /root/.config
   sudo tee /root/.config/renovate-trigger.token >/dev/null   # paste token, Ctrl-D
   sudo chmod 600 /root/.config/renovate-trigger.token
   ```

The deploy key used by the repo auto-pull **cannot** do this — deploy keys have no
Actions/dispatch API access, and the API needs a bearer token in the header.

The same token also fires the nightly health check, the edge access policy probe, the
deploy-state probe and the Tor bridge image checks — see [On-time trigger](nas-health-check.md#on-time-trigger),
[the edge probe's](edge-access-policy-probe.md#on-time-trigger),
[the deploy-state probe's](deploy-state-probe.md#on-time-trigger) and
[Tor bridge image trigger](#tor-bridge-image-trigger) below. Rotating it here rotates it for all six
trigger scripts.

## Cron jobs (TrueNAS → System → Advanced → Cron Jobs, run as root)

Alongside the existing backup crons (see
[NAS repo auto-pull](nas-repo-autopull.md) for the clone/pull mechanics). This is
what is live — verify with the `cronjob.query` below:

| id | Schedule | Command |
| --- | --- | --- |
| 6 | `15 4 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/renovate-trigger.sh` |
| 7 | `15 5 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/renovate-trigger.sh` |
| 12 | `20,35,50 5 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/merge-sweep-trigger.sh` |
| 18 | `40 3 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/tor-bridge-image-trigger.sh` |

The nightly health check and the edge access policy probe use the same mechanism on
crons of their own, documented in [nas-health-check.md](nas-health-check.md#on-time-trigger)
and [edge-access-policy-probe.md](edge-access-policy-probe.md#on-time-trigger).

- Invoke via `/bin/sh <path>` (not the bare path) so the exec bit is moot — the
  repo is authored on Windows.
- All are `user: root`, `enabled: true`, stdout **and** stderr suppressed — each
  script keeps its own log under `/var/log/`, so cron mail would only duplicate it.
- Clear of the 02:15/02:30/03:00 backup-job minutes.
- Create one from the shell rather than the UI if you prefer:

  ```sh
  midclt call cronjob.create '{"description":"...","command":"/bin/sh /mnt/apps/scripts/nas/scripts/<name>.sh",
    "user":"root","schedule":{"minute":"20,35,50","hour":"5","dom":"*","month":"*","dow":"*"},
    "enabled":true,"stdout":true,"stderr":true}'
  ```

### Merge-sweep trigger

The second cron is the same trick applied to the thing that actually merges.
[`scripts/merge-sweep-trigger.sh`](../../../scripts/merge-sweep-trigger.sh)
dispatches [`renovate-pr-review.yml`](../../../.github/workflows/renovate-pr-review.yml)
with no inputs, which is its sweep mode: merge every open Renovate stack PR whose
`renovate-review` status is green. Same token, same log pattern, own log file
(`/var/log/merge-sweep-trigger.log`).

**Why it exists.** That workflow's own `schedule:` cron is best-effort. On
**2026-07-30** exactly one of its eight slots materialised, 50 minutes late at
07:34 Vienna, logged `Berlin hour is 07 — outside the 05:00-06:00 window` and
merged nothing; ten already-cleared PRs sat open for a day. The GitHub schedule
is kept as a fallback for when the NAS is down.

- **:20 / :35 / :50, not :00** — `renovate-trigger.sh` runs at 05:15 and opens
  the morning's PRs; each one then triggers a review that takes a few minutes
  (the Claude pass). Starting at :20 lets the sweep act on this morning's bumps.
  Nothing breaks if a review is still running: an unreviewed PR has no
  `renovate-review` status yet, the sweep skips it, and it merges tomorrow.
- **Three, not one** — a dispatch can fail, and a review triggered at 05:00 may
  not have posted its status by :10. The sweep merges whatever is cleared and
  mergeable right now, so extra passes only pick up stragglers.
- **No `ignore_window` input** — the dispatched run still checks the Berlin hour
  itself. If this cron ever fires late (hung NAS, clock jump) the run declines to
  merge rather than redeploying stacks in the middle of the day.

### Tor bridge image trigger

[`scripts/tor-bridge-image-trigger.sh`](../../../scripts/tor-bridge-image-trigger.sh) dispatches
the daily freshness checks of both self-built Tor bridge images:
[`build-webtunnel-image.yml`](../../../.github/workflows/build-webtunnel-image.yml)
([WebTunnel](../../services/a1-vps-webtunnel.md#image-and-security-updates)) and
[`build-obfs4-image.yml`](../../../.github/workflows/build-obfs4-image.yml)
([obfs4](../../services/a1-vps-tor-bridge.md#image-and-security-updates)). Same token, same log
pattern, own log file (`/var/log/tor-bridge-image-trigger.log`). A failed dispatch of one still
dispatches the other, and the script exits non-zero.

- **03:40, before Renovate's 04:15 run.** A rebuild pushed by then becomes that run's compose PR,
  and its review has finished by the 05:20 sweep, so a Tor or Debian security fix is live on the A1
  the same morning.
- **Daily.** A run that finds the image current costs a few runner minutes and pushes nothing.
- Each workflow's own `schedule:` (03:10 UTC WebTunnel, 03:25 UTC obfs4) is the fallback. When both
  fire, the later run finds the image current.

Created 2026-09-14 as id 18 for WebTunnel only (`webtunnel-build-trigger.sh`, log
`/var/log/webtunnel-build-trigger.log`). On 2026-09-16 the script was renamed and took over the obfs4
image too, and the job's command changed with it. To recreate it:

```sh
midclt call cronjob.create '{"description":"Tor bridge image freshness checks","command":"/bin/sh /mnt/apps/scripts/nas/scripts/tor-bridge-image-trigger.sh",
  "user":"root","schedule":{"minute":"40","hour":"3","dom":"*","month":"*","dow":"*"},
  "enabled":true,"stdout":true,"stderr":true}'
```

## Verify / operate

```sh
# fire a run now and watch the log (merges only if it's currently 05-06 Vienna)
sudo /bin/sh /mnt/apps/scripts/nas/scripts/renovate-trigger.sh
sudo cat /var/log/renovate-trigger.log        # expect: "... dispatched renovate.yml (main)"

# same for the merge sweep
sudo /bin/sh /mnt/apps/scripts/nas/scripts/merge-sweep-trigger.sh
sudo cat /var/log/merge-sweep-trigger.log     # expect: "... dispatched renovate-pr-review.yml sweep (main)"

# confirm the run started on GitHub → Actions tab → renovate / renovate-pr-review
# (trigger: workflow_dispatch)

# list cron jobs (find the renovate-trigger id)
sudo midclt call cronjob.query '[]' '{"select":["id","description","command","schedule","enabled"]}'
```

Success = HTTP **204** from the dispatch endpoint (logged as `dispatched …`). Any
other status logs `ERROR: dispatch got HTTP <code>` and the cron exits non-zero.

## Gotchas

- **204, not 200.** `workflow_dispatch` returns `204 No Content`; the script treats
  anything else as failure. A `404` almost always means the token lacks **Actions:
  write** or can't see the repo; `401`/`403` = bad/expired token.
- **Dispatch runs the workflow from the default branch.** `ref: main` — the run
  always uses `main`'s `renovate.yml` and `renovate.json`, regardless of open PRs.
- **The GitHub `schedule:` cron is gone (2026-09-18).** The host cron dispatches
  are the only trigger. Don't add `schedule:` back expecting a fallback: GitHub
  drops most scheduled events since 2026-08-27, so it bills without firing.
- **A stack-PR backlog no longer drains one per run.** The review workflow's
  sweep merges every cleared PR in one pass inside the same window; each merge
  still triggers its own stack redeploy, and `deploy-stacks`'s concurrency group
  runs them one at a time. Renovate's one-merge-per-run limit now only affects
  `github-actions` PRs.
- **Don't set `rebaseWhen` back to `auto`/`behind-base-branch`.** It re-breaks the
  backlog: every merge invalidates the checks on all remaining branches. See
  [Why two dispatches and not twelve](#why-two-dispatches-and-not-twelve).
- **Token is not in git.** Root-only file `/root/.config/renovate-trigger.token`
  (or `RENOVATE_TRIGGER_TOKEN` env). Rotate by regenerating the fine-grained PAT and
  overwriting the file; test with a manual run.
- **Local edits to the clone are blown away** by the 15-min auto-pull — edit the
  script in the repo and push, never on the host.
