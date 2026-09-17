# Runbook: Renovate PR review (image delta + risk assessment)

## Why

[`renovate.json`](../../../renovate.json) pins every stack image to
`tag@sha256:…`. When the tag is already patch-level (`postgres:18.4`), Renovate
classifies a rebuild as a **digest** update — and a digest update has no version
delta, so the PR body has no release notes and no changelog link. The reviewer
sees this and nothing else:

| Package | Update | Change |
| --- | --- | --- |
| docker.io/library/postgres | digest | `32ca0af` → `3a82e1f` |

That is exactly the wrong place to have no information — and a version bump that
*does* carry release notes is not automatically safer. mealie
`v3.20.1 → v3.22.0` (PR #92) was an ordinary grouped minor bump; bundled inside
it, v3.21.0 made an OIDC `email_verified` claim mandatory, which Authentik's
default `email` scope mapping hardcodes to `False`. Merged unread, it would have
locked every account out of a stack whose only login path is OIDC.

So the gate is no longer "which images did we exempt from auto-merge": **every**
stack PR goes through both layers, and Renovate's own automerge is off for
`docker-compose`. The `needs-manual-review` label (Postgres, MariaDB, Valkey, Redis,
authentik, the Caddy build — where a bad bump means data loss, an auth lockout or
the edge down) survives as a visibility marker and as a hint to the agent, not as the
thing that decides who gets reviewed. What keeps those images out of the unattended
merge is `MERGE_SKIP_IMAGES` in Layer 4, not the label.

Two things are hiding inside "digest bump", and they are not the same risk:

- a base-OS rebuild, same upstream software — routine;
- a floating tag quietly advancing the upstream version (`postgres:18` moving
  18.4 → 18.5 with no tag change) — not routine.

…and a third case that is *no* risk at all but looks identical: the multi-arch
index digest moved because some **other** architecture (or an attestation blob)
was rebuilt, while the manifest this host actually pulls is byte-identical.

## How it works

[`.github/workflows/renovate-pr-review.yml`](../../../.github/workflows/renovate-pr-review.yml)
runs on every `pull_request` event from a `renovate/*` branch. Four layers:
two that work out what changed, one that publishes the verdict as a required
commit status, and one that merges the cleared PRs at 05:00.

```text
layer 1  registry image delta ─┐
layer 2  Claude risk verdict  ─┴─> layer 3  renovate-review status  ──> layer 4  05:00 sweep
                                            (required check on main)      └─> deploy-stacks
                                   red ──> PR comment ──> email to you
```

### Layer 1 — deterministic image delta

[`scripts/renovate-image-delta.sh`](../../../scripts/renovate-image-delta.sh)
takes the PR's base and head SHAs, pulls every changed `image:` line out of
`stacks/**/docker-compose.yml`, and resolves **both** digests through the
registry API — anonymously; the Bearer realm is discovered from the registry's
own 401 challenge, so Docker Hub, `ghcr.io` and `lscr.io` all work with no
credentials and nothing is pulled.

For each image it:

1. resolves the multi-arch index to the child manifest for the platform that
   stack runs on (arm64 for every `stacks/a1-vps-*/`, amd64 everywhere else — a
   lookup in the script). **Same child digest on both sides ⇒ NO-OP**, reported
   as such and nothing further is needed;
2. otherwise reads the image config blob for each side and diffs `created`, the
   `org.opencontainers.image.*` labels, the upstream version env vars
   (`PG_VERSION`, `REDIS_VERSION`, `VALKEY_VERSION`, `PARADEDB_VERSION`, …) and
   the rootfs layer list.

It ends with a machine-readable `DELTA: NOOP | CHANGED | UNKNOWN` line that the
workflow greps and then strips from the comment.

Costs nothing, runs on every Renovate stack PR. Real output, PR #94:

> **NO-OP for amd64.** Index digest `32ca0af` → `3a82e1f`, but both resolve to
> the same amd64 manifest `d93de42662696f278fb` […] The image this host pulls is
> byte-identical.

…while the redis line in the same PR showed `REDIS_VERSION=8.8.0` → `8.8.1`
with 5 of 7 layers rebuilt.

### Layer 2 — Claude risk assessment

Runs on **every** stack PR whose delta came back `CHANGED` — a no-op needs no
assessment and an unresolvable delta cannot be merged either way, so neither
pays for one. That is roughly one agent run per real image change (~$0.45 each
at the observed usage), where it used to be a handful a week. Same headless-agent
pattern as
[`nas-health-check`](nas-health-check.md): the CLI runs `claude -p` against
[`.github/renovate-pr-review.md`](../../../.github/renovate-pr-review.md), which
tells it to read the layer-1 delta, the PR diff, `docs/services/<stack>.md`, and
the upstream release notes (via `WebFetch`), then write a short verdict ending in
`RISK: LOW` or `RISK: REVIEW`.

Tools are `Read,Glob,Grep,WebFetch,Bash(git diff:*),Bash(git log:*)` — no write
tools; its stdout is the whole deliverable. Token usage, cost and the estimated
share of a 5-hour Claude Pro session the run consumed are appended to the
comment. That percentage uses the same weighting and 1.5M-token default as
[`nas-health-check`](nas-health-check.md#operations) — override with the
`CLAUDE_SESSION_TOKEN_BUDGET` repo variable, in both workflows.

### Layer 3 — the `renovate-review` status

The verdict of layers 1+2 is published as a **commit status on the PR's head
SHA**, context `renovate-review`:

| Status | When |
| --- | --- |
| `success` | `DELTA: NOOP` (the manifest this host pulls is byte-identical, so the agent never ran), or `RISK: LOW` |
| `success` | nothing to review: the PR changes no `stacks/**/docker-compose.yml` (a github-actions bump, or a bump of what `stacks/caddy/Dockerfile` builds from), or it is not a `renovate/*` branch at all |
| `failure` | `RISK: REVIEW`, `DELTA: UNKNOWN`, no usable agent verdict, or no Claude secret so nothing assessed the change |
| *missing* | the review never ran or never finished — fails closed, nothing merges |

Note the two green rows are not the same thing: the first cleared a stack image,
the second had nothing to assess. The sweep reads only the status, so it merges
both — a github-actions bump Renovate has not merged yet, and a
`stacks/caddy/Dockerfile` bump, which only rebuilds the edge image (the digest PR
that follows is held by `MERGE_SKIP_IMAGES`). A red status on one of those would
deadlock it against the required check, which is why "nothing to review" is green
rather than red.

`renovate-review` is a **required check on `main`**, so a flagged PR is also held
back from a hand-merge. `enforce_admins` is off on this repo, so you can still
merge over it deliberately — that is the intended escape hatch, not a hole.

**Why a posted status and not the review job's own conclusion.** A
`workflow_dispatch` run is not attached to the PR and produces no check run on
its head commit — and dispatch is exactly how you re-review a branch cut before
this workflow landed. A status posted on the SHA behaves the same whichever event
produced it. It also makes head-drift handling free: a status belongs to one
commit, so a force-push voids the clearance by itself, with no marker to compare.

Every PR gets the status, including hand-written ones — the `gate-passthrough`
job posts a green one for any non-`renovate/*` branch. A required status
*context* has no "skipped" state (unlike a skipped job, which counts as passing),
so a context that is never posted would block that PR forever.

### Layer 4 — the merge sweep, in the 05:00-06:00 window

**Clearing is not merging.** The `window-merge` job sweeps every open
`renovate/*` PR, reads back its `renovate-review` status, and merges the green
ones — so a bump reviewed at 14:00 still redeploys at 05:00, when nothing is
using the NAS. Unlike Renovate (one merge per run) the sweep drains the whole
queue in one pass.

**It merges one at a time, and waits for the deploy in between.** `deploy-stacks`
has `concurrency: deploy-stacks`, which serialises the *running* deploy — but
GitHub keeps only **one pending run per group**, so back-to-back merges cancel the
waiting run before any job starts and its webhook never fires. Nine runs were
cancelled that way between 2026-07-31 and 2026-08-08; five stacks stayed on old
images for up to 14 days and the nightly health check went red 13 nights running.
So after each merge the sweep polls `deploy-stacks`' run list until nothing is
queued or in progress (`DEPLOY_WAIT`, 420s cap, then it merges on anyway and lets
Komodo's hourly `reconcile-owned` Procedure clean up, [deploy-stacks.md](deploy-stacks.md)). That is why
`timeout-minutes` is 45 and why `permissions:` needs `actions: read`.

**Two things the sweep refuses to merge, whatever the review said.**

1. **`MERGE_SKIP` stacks** — matched on touched paths, currently none. It held `portainer`, the
   control plane, until Portainer's removal on 2026-09-17.
2. **`MERGE_SKIP_IMAGES`** — matched on the **image a PR bumps**, not the stack folder:
   `postgres`, `valkey/valkey`, `redis`, `mariadb`, `ghcr.io/goauthentik/server`,
   `ghcr.io/immich-app/postgres`, `ghcr.io/drizzelat/nas-caddy`. A bad bump here means data
   loss, a full auth lockout or the whole edge down, so no risk verdict — deterministic or
   otherwise — merges one unattended. `nas-caddy` is there for a different reason than the
   rest: it is built from this repo, and its digest PR shows the new digest but not which
   branch's Dockerfile produced it. See [caddy.md](../../services/caddy.md).

> **Why image-level and not per-stack.** Renovate groups by `{{packageFileDir}}`, so an
> `immich` PR can carry `immich-server` *and* the pgvecto Postgres. Skipping the whole stack
> would hand-hold every app bump too; matching the image means the app still sweeps while its
> database waits. The regex anchors on `[:@]` after the repo path, so `postgres` does not
> match `postgres-exporter`.
>
> **This closes a real gap, and it is the opposite of what
> [SEC-6](../../architecture-review-2026-08-20.md#sec-6--llm-verdict-is-a-required-merge-gate)
> proposed.** That finding argued the LLM verdict could be downgraded to advisory *because*
> the stateful paths were "already hand-held via `MERGE_SKIP` and `needs-manual-review`". They
> were not: `MERGE_SKIP` held only `portainer`, and the `needs-manual-review` label plus
> `automerge: false` in [`renovate.json`](../../../renovate.json) only govern **Renovate's own**
> automerge — this sweep merges with `gh pr merge` and never read either. Database and SSO
> bumps were auto-merging on `RISK: LOW`. Downgrading the LLM would have made that worse, so
> the hand-holding was made real instead.

**The stale-clearance alarm mirrors both lists.** A held PR sits green-but-unmerged on
purpose, so without the same exclusions it would alarm every day as a broken sweep.

**`github-runner` is no longer merged last.** Its stack *is* the self-hosted runner,
and recreating that container killed whatever job ran next (exit 143 — it took out
the 2026-08-01 deploy), so the sweep sorted it to the end. Since 2026-09-17 a merge
deploys nothing for it: Komodo's `deploy-runner` Procedure recreates it within the
hour, between jobs ([github-runner.md](../../services/github-runner.md#deploy-path)).

Before each merge it re-checks everything that could have changed since the
review: still open, not a draft, `renovate-review` green **on the current head**,
not a `MERGE_SKIP` stack, no conflicts, no failing checks, `validate` green, and
`gh pr merge --match-head-commit` as the last guard against a race with the merge
itself.

**Two triggers, because GitHub's is unreliable.**

| Trigger | What it is |
| --- | --- |
| TrueNAS cron → `workflow_dispatch`, **05:20 / 05:35 / 05:50 Vienna** | The primary one. A dispatch runs promptly, so the wall-clock minute is ours. [`scripts/merge-sweep-trigger.sh`](../../../scripts/merge-sweep-trigger.sh), cron entries in the [Renovate trigger runbook](renovate-trigger.md#merge-sweep-trigger) |
| `schedule:` every 10 min of 03 + 04 UTC | Fallback for when the NAS is down. Only half the slots can ever merge — 03:xx UTC is 05:xx Berlin in summer, 04:xx UTC in winter — and the job checks the Berlin hour itself rather than doing DST arithmetic in cron |

Why the host cron exists: on **2026-07-30**, of eight scheduled slots exactly
*one* materialised, 50 minutes late at 07:34 Vienna. It logged `Berlin hour is 07
— outside the 05:00-06:00 window, nothing to do` and merged nothing, while ten
already-cleared PRs sat open. GitHub Actions `schedule:` is queued, best-effort,
and dropped under load. Same failure and same fix as
[`renovate-trigger.sh`](renovate-trigger.md).

To merge outside the window, run the sweep by hand:

```sh
gh workflow run renovate-pr-review.yml -f ignore_window=true   # no `pr` input = sweep mode
```

To exercise the sweep at any hour **without merging anything** — the way to check
it still works after touching it:

```sh
gh workflow run renovate-pr-review.yml -f ignore_window=true -f dry_run=true
```

That runs every gate and logs `WOULD MERGE` per PR. Worth doing after any change
to the job or its `permissions:` block: on 2026-07-31 three perfectly-timed
in-window sweeps merged nothing, and the cause was a permission the job never
knew it needed (see below). The failure cost a whole morning; a dry run shows it
in 30 seconds.

### Why the sweep reads REST and not `gh pr view`

`gh pr view --json statusCheckRollup` looks like the obvious way to get
mergeability and checks in one call. It issues a GraphQL query of **gh's**
choosing, which walks `statusCheckRollup.contexts.checkSuite.workflowRun` — a
field the sweep has no use for and the job token had no permission for. GraphQL
refused the whole query, so every PR read failed:

```text
Resource not accessible by integration
  (repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0.checkSuite.workflowRun)
```

The sweep therefore uses three explicit REST reads instead — `/pulls/{n}` for
mergeability, `/commits/{sha}/status` for the `renovate-review` verdict,
`/commits/{sha}/check-runs` for `validate` and any failed job. What each call
needs is exactly what it returns, and no gh upgrade can widen it behind our back.

Note the two are different resources on the same commit: **commit statuses**
(`statuses: write`, what this workflow posts) and **check runs**
(`checks: read`, what Actions jobs produce). Both are read; both grants are
required.

Three deliberate design points:

- **Separate job.** The merge job holds the merge credential; it checks out only
  this repo's `scripts/review/`, never PR-authored content, so there is nothing
  there to hijack it. Do not give it a `fetch-depth: 0` PR checkout.
- **The Renovate App token, not `GITHUB_TOKEN`.** A push made with `GITHUB_TOKEN`
  does not trigger workflows — a `GITHUB_TOKEN` merge would land the new pin on
  `main` and [`deploy-stacks`](../../../.github/workflows/deploy-stacks.yml) would
  never fire. The image would be pinned and never deployed, with nothing going red.
  An App installation token does trigger them, and merges as the same identity that
  opened the PR.
- **The verdict travels in the commit status, not in job outputs.** The run that
  cleared the PR finished hours before the sweep starts, so there is no job
  output left to read.

### A comment means "look at this"

A **new** PR comment emails you, so the workflow only ever posts one when the
review did **not** clear the PR. Cleared PRs are silent: green status, full
detail in the workflow run log. An existing comment is always PATCHed — an edit
does not notify — so a PR that was flagged and later clears keeps its trail
without mailing you a second time.

That means silence is the healthy state, which needs a dead-man's switch: the
**`stale-clearance`** job, on its own cron slot at `30 8 * * *` UTC (~10:30
Vienna), goes red — and GitHub mails the failure — if any stack PR has held a
green `renovate-review` for more than 24 h and is still open. That is precisely
the shape of the 2026-07-30 breakage. `MERGE_SKIP` stacks and non-stack PRs are
excluded; they are cleared-but-unmerged by design and would alarm every day.

Once a day at most, and only when something is genuinely stuck. Everything else
you hear about stays as it was: a red `deploy-stacks`, a red health check, a PR
comment on something that needs a decision.

## Where the logic lives

This workflow carried **817 lines**, nearly all bash inside YAML
([CPX-1](../../architecture-review-2026-08-20.md#cpx-1--1500-lines-of-bash-inside-yaml)). It is
now **250 lines** of orchestration, with the substance in real files:

| Script | Layer |
| --- | --- |
| [`scripts/review/pr-context.sh`](../../../scripts/review/pr-context.sh) | PR number/head/branch, and whether a stack compose moved |
| [`scripts/review/image-delta.sh`](../../../scripts/review/image-delta.sh) | Layer 1 — deterministic registry delta (`NOOP` / `CHANGED` / `UNKNOWN`) |
| [`scripts/review/assess-risk.sh`](../../../scripts/review/assess-risk.sh) | Layer 2 — the Claude risk pass |
| [`scripts/review/decide-verdict.sh`](../../../scripts/review/decide-verdict.sh) | Layer 3 — combines both into the status + automerge flag |
| [`scripts/review/comment.sh`](../../../scripts/review/comment.sh) | The PR comment, posted only when a human is needed |
| [`scripts/review/merge-sweep.sh`](../../../scripts/review/merge-sweep.sh) | Layer 4 — the 05:00 sweep |
| [`scripts/review/stale-alarm.sh`](../../../scripts/review/stale-alarm.sh) | The cleared-but-unmerged alarm |

Four short steps stay inline (the agent-should-run test, the CLI install, and the two
status posts) — a four-line `npm install` in its own file is noise, not clarity.

**Every job that calls one needs `actions/checkout`.** Inline bash was carried in the workflow
file itself; a script has to be fetched. `window-merge` and `stale-clearance` run on
`ubuntu-latest` and never checked out before, so both gained a checkout step — without it the
sweep dies with `scripts/review/merge-sweep.sh: No such file or directory` and exit 127.

Every script is driven purely by environment variables; no `${{ }}` expression appears inside
one. The `env:` block on the matching step **is** the script's interface, which is what lets
these run outside Actions. `shellcheck -S warning` covers them in CI, and the same job asserts
they are executable in git.

### Testing a change to the sweep

The sweep is the dangerous one — it merges to `main` and triggers deploys. Both a dry run and an
out-of-window run are supported, so it never has to be tested for real:

```sh
gh workflow run renovate-pr-review.yml -f ignore_window=true -f dry_run=true
```

It then prints `#<n>: WOULD MERGE (dry run).` per PR and merges nothing.

## Setup

Nothing beyond what the health check already needs:

| Secret | Used for |
| --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`) | layer 2 only — shared with `nas-health-check` |
| `GITHUB_TOKEN` (automatic) | the `renovate-review` status (`statuses: write`), the comment (`pull-requests: write`), reading PRs in the sweep |
| `RENOVATE_APP_CLIENT_ID` + `RENOVATE_APP_PRIVATE_KEY` | layer 4 only — `window-merge` mints a Renovate App installation token from them, narrowed to `contents: write` + `pull-requests: write`, so the merge lands as the same identity that opened the PR. Already set for [`renovate.yml`](../../../.github/workflows/renovate.yml); setup in [Renovate as a GitHub App](renovate-github-app.md) |

Plus two things outside the workflow file:

- **`renovate-review` as a required check on `main`**, alongside `validate`:

  ```sh
  gh api -X PATCH repos/drizzelat/NAS/branches/main/protection/required_status_checks \
    -f 'contexts[]=validate' -f 'contexts[]=renovate-review'
  ```

  Add it only once the workflow that posts it is on `main`, or every open PR is
  blocked until it gets re-reviewed (`gh workflow run renovate-pr-review.yml -f pr=<N>`).

- **The merge-sweep host cron** — see the [Renovate trigger
  runbook](renovate-trigger.md#merge-sweep-trigger). It reuses the fine-grained
  PAT that is already on the NAS for `renovate-trigger.sh`; no new secret.

If neither Claude secret is set, layer 2 is skipped and the status goes **red**
with "no Claude secret" — nothing merges except no-ops. Set one with
`claude setup-token` → `gh secret set CLAUDE_CODE_OAUTH_TOKEN`.

Without the Renovate App secrets the review still runs and still clears PRs; the
mint step is `continue-on-error`, so the sweep logs `no merge token` and merges
nothing rather than going red. Since Renovate no longer merges stack PRs
either, that means **every stack bump waits for a hand-merge** — the intended
failure direction, and the `stale-clearance` alarm will tell you within a day.

## Re-running it by hand

A `pull_request` run uses the workflow file from the **PR's head branch**, not
from `main`. A Renovate branch cut before this workflow landed therefore never
triggers it — no event, no label, no re-open will help. `workflow_dispatch` runs
from `main` instead and takes a PR number:

```sh
gh workflow run renovate-pr-review.yml -f pr=94
```

Same for re-running after a registry rate-limit or an agent hiccup. Branches
Renovate cuts from now on carry the workflow and trigger on their own.

A dispatch **reviews only** — it re-posts the `renovate-review` status (and the
comment, if the PR needs one); the merge still waits for the window. A dispatch
with **no** `pr` input is the other mode: it runs the merge sweep instead (add
`-f ignore_window=true` to merge outside 05:00-06:00).

Re-review every open Renovate PR at once — the way to bootstrap the status on
branches that predate it:

```sh
for n in $(gh pr list --state open --json number,headRefName \
             --jq '.[] | select(.headRefName | startswith("renovate/")) | .number'); do
  gh workflow run renovate-pr-review.yml -f pr="$n"
done
```

## Rules this workflow lives by

- **GitHub-hosted runner only.** It is a `pull_request` workflow; running PR
  content on the `[self-hosted, nas]` runner would be RCE on the NAS. Same rule
  as [`compose-validate`](../../../.github/workflows/compose-validate.yml).
- **`pull_request`, not `pull_request_target`** — the checkout never shares a
  context with write credentials. Renovate's branches are internal (not forks),
  so the checkout is trusted anyway.
- **The `review` job must never go red.** Its verdict travels in the status it
  posts, not in its own conclusion, so a red job would say nothing useful — and
  the sweep refuses any PR with a failing check, so it would stall merges rather
  than gate them. Every analysis step swallows its own errors and reports the
  problem inside the comment; "not cleared" is a red `renovate-review` status,
  never a failed job. A job that dies outright posts no status at all, which
  fails closed against the required check — the correct direction.
- **`window-merge` and `stale-clearance` may go red**, and `stale-clearance` is
  *meant* to. Both are scheduled-only (`if:` on the event), so neither ever runs
  on a `pull_request` event and nothing on a PR depends on their conclusion.
- **`renovate-review` is a required check on `main`; the workflow's own job names
  are not.** Require the status context, never `review` — that job is skipped on
  hand-written PRs.

## Related: pin patch-level tags, not floating ones

The delta script exists because a digest bump can hide a version change — but on
a **floating** tag it can hide a *bigger* one. `postgres:18-alpine` advancing
18.4 → 18.5 arrives as a digest update with no changelog; `postgres:18.4-alpine`
advancing to `18.5-alpine` arrives as a visible patch update with release notes
in the PR body, and never needs the script at all.

`stacks/a1-vps-matrix/` was the last stateful image on a floating minor tag; it
is now pinned to the patch tag (2026-07-29, same digest — the tag was pointing
there already). Keep new stateful images pinned the same way.

Remaining floating tags are on stateless services — `caddy:2-alpine` (the A1's
Matrix edge) and `nginx:alpine` (the micro VPS ingress) — plus
`ghcr.io/immich-app/postgres:18-vectorchord0.5.3`, whose bespoke vendor tag
cannot be pinned finer; layer 1 surfaces its `PG_VERSION` changes instead.
(`portainer-ee` has since moved off `latest` to an explicit version.)

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Comment says "Could not fetch manifests" | Registry rate-limited the anonymous token (Docker Hub does this per-IP). Re-run the job; the next Renovate `synchronize` also refreshes it. |
| Comment says "Not digest-pinned" | The image lost its `@sha256:` pin — `pinDigests` should have prevented that. Check the compose file. |
| No comment at all | **Normal for a cleared PR** — comments are only posted when the review did not clear it. Otherwise: head branch is not `renovate/*` (the job's `if:`), or the review never ran. |
| Layer 2 never runs | The delta was `NOOP` or `UNKNOWN`, the PR changed no stack compose file, or neither Claude secret is set — the "Should run the agent?" step logs which. |
| Duplicate comments | The `<!-- renovate-image-delta` marker lookup failed. Delete the extras; the next run reuses the oldest. |
| A PR is stuck on `renovate-review` `Expected — Waiting for status` | Nothing ever posted the status: the review job died, or the branch predates this workflow. Re-review it: `gh workflow run renovate-pr-review.yml -f pr=<N>`. |
| Your own (non-Renovate) PR is blocked on `renovate-review` | The `gate-passthrough` job should have posted a green one. Re-run the workflow on that PR, or push an empty commit. |
| Nothing merged this morning | Check the `window-merge` job: it logs one line per PR (`no renovate-review status`, `renovate-review=FAILURE`, `mergeable=…`). If the job never ran *in-window*, the host cron did not fire — check `/var/log/merge-sweep-trigger.log` on the NAS. The `stale-clearance` alarm mails you about this within a day. |
| `could not read the PR / status / check runs` on **every** PR | A permission the job lacks. The warning quotes what `gh` said — read it, it names the resource. Reproduce and confirm a fix with `-f ignore_window=true -f dry_run=true`. This is what a missing grant looks like; see [why the sweep reads REST](#why-the-sweep-reads-rest-and-not-gh-pr-view). |
| PR cleared but not merged | The sweep's per-PR line says why; `failing checks` also appears as a `::warning::`. `no renovate-review status on <sha>` means Renovate force-pushed after the review — the re-review that push triggered re-clears it. |
| `stale-clearance` went red | A cleared PR sat unmerged for >24 h. Almost always the sweep never ran in-window; the job names the PRs. Merge them now with `gh workflow run renovate-pr-review.yml -f ignore_window=true` if you don't want to wait for 05:00. |
| Merged but the stack didn't redeploy | First look for a **cancelled** `deploy-stacks` run at that SHA (`gh run list --workflow=deploy-stacks.yml`): a cancelled run has *zero jobs* and fired no webhook — GitHub evicted it from the concurrency queue behind a later merge. Komodo's hourly `reconcile-owned` Procedure deploys it at `:23`; force it now with `gh workflow run deploy-stacks.yml -f stacks=<stack>`. Otherwise: `deploy-stacks` only fires on `stacks/**`, so a merge that changed nothing there has nothing to deploy; and check the merge was authored by the Renovate App bot, not `GITHUB_TOKEN` (the latter does not trigger workflows). |
| Want one image never auto-merged | Nothing merges unreviewed any more, so the lever is the agent: `RISK: REVIEW` parks it. To stop *all* unattended merges, delete `RENOVATE_APP_PRIVATE_KEY`. |

Run layer 1 by hand against any PR:

```sh
git fetch origin refs/pull/<N>/head:pr<N>
bash scripts/renovate-image-delta.sh "$(git merge-base main pr<N>)" pr<N>
```
