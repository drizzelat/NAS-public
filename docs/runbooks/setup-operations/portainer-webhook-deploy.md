# Runbook: Per-stack deploy via self-hosted runner + Portainer webhooks

> **Retired 2026-09-17; historical.** `deploy-stacks` no longer calls Portainer at all: see
> [deploy-stacks.md](deploy-stacks.md). The reasoning below still explains why the convergence gate,
> the rollback rules and `DEFER_FIRE` exist; the Portainer calls, the reconcile pass and Pass 1's
> delete are gone.

Goal: stop GitOps polling from redeploying **every** stack on **every** commit.
Instead a self-hosted GitHub runner fires the Portainer **webhook** only for the
stack whose folder changed. Portainer stays LAN-only (not exposed to the internet).

Pieces:

- `stacks/github-runner/` — the runner (see [service doc](../../services/github-runner.md))
- `.github/workflows/deploy-stacks.yml` — diff push → for each changed stack, either
  fire its webhook from Portainer (`GET /api/stacks`, `.AutoUpdate.Webhook`) if it
  exists, or **create it** from the repo if it's new (see "New stack added later")
- `scripts/portainer-migrate/read-webhooks.ps1` — read-only helper to *inspect* the
  stack=uuid mapping. The workflow discovers it live now, so this is optional
  (handy to see which stacks still poll / lack a webhook)

## Prerequisites

1. Stacks already migrated to Git (GitOps) stacks — see
   [Portainer GitOps migration runbook](../setup-operations/portainer-gitops-migration.md).
2. **GitHub PAT for the runner.** Classic token: scope `repo`. Fine-grained:
   `Administration: Read and write` on `drizzelat/NAS`. This lets the container
   self-register as a runner.

## Step 1 — Deploy the runner stack

The runner can't deploy itself the first time, so add it manually:

1. Portainer → **Stacks → Add stack → Repository**.
2. Repo URL `https://github.com/drizzelat/NAS`, branch `main`,
   compose path `stacks/github-runner/docker-compose.yml`.
3. Under **Environment variables** add `RUNNER_PAT` = your GitHub PAT.
4. Enable GitOps webhook update (so the runner stack itself can self-update later).
5. Deploy. Confirm in **GitHub → repo → Settings → Actions → Runners** that
   `nas-runner` shows up (it appears only while a job runs, since it's ephemeral).

## Step 2 — Flip stacks from polling to webhook

Portainer **2.39 has no API to change a stack's auto-update mode** (`PUT
/api/stacks/{id}/git` → 405). Do it in the UI, per git stack (all except
`github-runner`, which already got its webhook at creation):

1. Portainer → **Stacks** → click the stack.
2. **GitOps updates** section → turn **off** the polling interval, turn **on**
   **Webhook**.
3. **Apply changes** / **Update**.

That's all CI needs. The `deploy-stacks` workflow reads each changed stack's webhook
straight from Portainer at run time (with `PORTAINER_API_TOKEN`), so there is **no
`stack=uuid` list to copy anywhere**. To eyeball the current mapping (which stacks
still poll / lack a webhook), run the read-only helper:

```powershell
.\scripts\portainer-migrate\read-webhooks.ps1
```

It warns about any stack still on polling or missing a webhook, then prints
`adguard=<uuid>` … one line per stack — purely for inspection now.

## Step 3 — Configure the workflow's GitHub repo settings

In **GitHub → repo → Settings → Secrets and variables → Actions**:

- **Variable** `PORTAINER_URL` = `https://192.168.178.111:31015`
- **Secret** `PORTAINER_API_TOKEN` = a **fresh** Portainer API key
  (Portainer → My account → Access tokens). Used to **discover each changed
  stack's webhook** (`GET /api/stacks`), by the post-deploy health check to read
  container state via the API proxy, and to **create brand-new stacks** (see
  Step 5). Because create/redeploy mutate, this key must be **write-scoped** (mint
  it from a user with write access — the same key `scripts/secrets.sh push` uses). Do
  **not** reuse any token from git history. (No `PORTAINER_WEBHOOKS` secret anymore —
  the mapping is fetched live.)
- **No vault key.** There is deliberately no `AGE_IDENTITY` secret: it decrypts the whole
  vault, so seeding a new stack's env is a workstation step now — see [SEC-1 step
  2](../../architecture-review-2026-08-20.md#step-3--remove-age_identity-from-ci).
- **No git-credential variable.** There used to be a `PORTAINER_GIT_CREDENTIAL_ID`
  repo variable holding the numeric ID of the Portainer git credential. Portainer EE
  2.45.0 removed `RepositoryGitCredentialID` from the stack-create payload and replaced
  it with **`SourceID`**, which carries the URL and the credential together. Both
  scripts now resolve that themselves from `GET /api/gitops/sources`, so there is
  nothing to configure. The variable was deleted on 2026-09-09. Details:
  [filebrowser-to-quantum](filebrowser-to-quantum.md) → `SourceID`.

### TLS: the API is reached with a pinned public key, not `-k` alone

Every Portainer API call used to be `curl -k` — certificate verification off, with the
write-scoped `X-API-Key` crossing that connection. Anyone able to MITM the path obtained the
control plane ([SEC-4](../../architecture-review-2026-08-20.md#sec-4--tls-verification-disabled-on-every-portainer-call)).

The obvious fix — commit the self-signed cert and swap `-k` for `--cacert` — **does not work
here.** Portainer's certificate has `X509v3 Subject Alternative Name: DNS:localhost,
IP Address:0.0.0.0`, so it can never validate the name `192.168.178.111` no matter which CA
bundle is supplied.

Instead the calls pin the server's **public key**, which is checked independently of CA and
hostname validation:

```yaml
env:
  PORTAINER_PIN: "sha256//z7ZZzbgczqzpEWcpCn5rrTrSAG+dMyYDMlaNl2rhoyI="
```

```sh
curl --pinnedpubkey "$PORTAINER_PIN" -kfsS -H "X-API-Key: $PORTAINER_TOKEN" ...
```

`-k` stays because the hostname genuinely cannot validate; the pin is what stops a MITM. A
mismatch fails the call with `curl: (90) SSL: public key does not match pinned public key`.
Verified in the runner container (curl 7.68 / OpenSSL 1.1.1f) as well as on the host.

The pin lives in the workflow files, not a secret — a public key hash is public data, and keeping
it in git means it is reviewable. It is set in `deploy-stacks.yml` and in `scripts/secrets.sh`.

**Rotating it.** The current certificate expires **2031-04-18**. If Portainer is reinstalled or
its cert is replaced, every API call fails with exit 90 — loudly, which is the point. Recompute
and update all three call sites:

```sh
echo | openssl s_client -connect 192.168.178.111:31015 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | openssl base64
```

> **Better long-term:** give Portainer a certificate whose SAN actually covers the LAN IP, then
> `--cacert` works and `-k` can go. That means changing the control plane's own TLS config, so it
> is deliberately not bundled with this change.

## What auto-rollback can and cannot undo

The health gate reverts a stack's **files in git** and re-fires its webhook. That is the whole of
it, and the limit matters:

| Damage | Rollback fixes it? |
| --- | --- |
| A bad image pin | **Yes** — revert + redeploy |
| A bad compose change | **Yes** |
| A container that will not start | **Yes**, by restoring the previous definition |
| Anything written to a **host filesystem** | **No** |
| A migrated database | **No** — [`renovate.json`](../../../renovate.json) says this too |

On 2026-08-21 a compose `configs:` block whose target sat inside a bind-mounted directory was
materialised **onto the A1's host filesystem**, overwriting Synapse's real `homeserver.yaml` and
both appservice registrations. Rollback did exactly what it is built to do — reverted the compose
on `main` — and the service stayed down, because the damage was on disk, not in git. Recovery was
manual, from copies taken before the change.

**Before any change that can write to a host path, take a copy first.** The rollback is a net for
git mistakes, not for filesystem ones.

## Where the deploy logic lives

`deploy-stacks.yml` used to carry **742 lines**, almost all of it bash inside YAML: no
shellcheck, no local execution, every fix a push-to-`main` experiment
([CPX-1](../../architecture-review-2026-08-20.md#cpx-1--1500-lines-of-bash-inside-yaml)).
The workflow is now **97 lines** of orchestration and the logic sits in real files:

| Script | What it does |
| --- | --- |
| [`scripts/deploy/fire-webhooks.sh`](../../../scripts/deploy/fire-webhooks.sh) | Pass 1 deletes removed stacks, then creates new ones and fires webhooks for changed folders |
| [`scripts/deploy/verify-healthy.sh`](../../../scripts/deploy/verify-healthy.sh) | Convergence + health polling, and the auto-rollback |
| [`scripts/deploy/fire-deferred.sh`](../../../scripts/deploy/fire-deferred.sh) | Fires the `DEFER_FIRE` webhooks last (github-runner hosts the job), or Komodo's `DeployStack` for a Komodo-owned one |
| [`scripts/komodo/lib.sh`](../../../scripts/komodo/lib.sh) | Sourced by the first two: the Komodo API calls for stacks in [`komodo/owned-stacks`](../../../komodo/owned-stacks) |

**Komodo-owned stacks skip Portainer entirely.** A stack named in `komodo/owned-stacks` is deployed
with Komodo's `DeployStack` instead of its webhook, is left out of the reconcile pass, and is never
deleted through Portainer. Verification and auto-rollback are unchanged. See
[komodo.md → Adopted stacks](../../services/komodo.md#adopted-stacks-phase-2).

**They are driven entirely by environment variables** — the workflow sets them, the scripts
read them. No `${{ }}` expression appears inside any script, which is what makes them runnable
outside Actions.

### Running one by hand

Because the inputs are just env vars, a script can be exercised against the real Portainer (or a
stub) from any machine that can reach it:

```sh
export PORTAINER_URL=https://192.168.178.111:31015
export PORTAINER_PIN="sha256//z7ZZzbgczqzpEWcpCn5rrTrSAG+dMyYDMlaNl2rhoyI="
export PORTAINER_TOKEN=<a write-scoped key>
export BEFORE=<sha> AFTER=<sha> EVENT=push DISPATCH_STACKS="" RECONCILE=false
export REPO_URL=https://github.com/drizzelat/NAS.git GIT_REF=refs/heads/main
scripts/deploy/fire-webhooks.sh
```

Read the `env:` block of the matching step in
[`deploy-stacks.yml`](../../../.github/workflows/deploy-stacks.yml) for the authoritative list —
that block *is* the script's interface.

### CI lints them

The `shellcheck` job in [`compose-validate.yml`](../../../.github/workflows/compose-validate.yml)
runs `shellcheck -S warning` over every `*.sh` in the repo, and separately asserts that
`scripts/deploy/*.sh` are **executable in git** — a missing exec bit is invisible locally and
fails as `Permission denied` only once it reaches production.

`-S warning` rather than the default: these scripts deliberately word-split some list variables,
which is style-level noise rather than a defect.

## Step 4 — Test

```powershell
# touch only one stack and push
git commit --allow-empty -m "test: webhook deploy" ; git push   # no-op, won't match paths
```

Better: make a trivial change in one stack folder, push, then watch
**GitHub → Actions** — the `deploy-stacks` run should list only that stack and
POST its webhook. Confirm in Portainer that only that stack redeployed.

## Notes & gotchas

- **A push is not the only trigger — every run reconciles.** After the pushed
  folders are handled, the fire step walks *all* stacks, compares each pinned
  `sha256:` in `stacks/<name>/docker-compose.yml` against the digest each
  container was actually created from (`.Config.Image` via the Portainer proxy),
  and redeploys the mismatches. This is deliberately self-healing: a
  push-triggered run can disappear (see the next two bullets), and before the
  reconcile pass the merged pin then sat on `main` undeployed **forever**, because
  a run only ever looked at its own `before..after` range. Found 2026-08-13 with
  5 stacks stale for up to 14 days and 13 consecutive red health checks.
  - Direction is one-way on purpose: a digest *running* that the repo does not pin
    = stale. Pinned-but-not-running is ignored — compose profiles and one-shot
    services would otherwise false-positive every night.
  - `RECONCILE_SKIP` = `github-runner` (a drift-triggered redeploy would fire
    mid-run, before the deferred step that exists to avoid exactly that),
    `portainer` (a TrueNAS app, not a stack), and `micro-vps-agent`/`a1-vps-agent`
    (redeploying an agent through itself drops its own endpoint).
  - Turn it off for one run with `gh workflow run deploy-stacks.yml -f reconcile=false`.
- **A run verifies against the LIVE tip of main, not just its own checkout.** Each
  run checks out its trigger SHA, which can already be stale by the time the health
  check looks at it. On **2026-08-21** the paperless run (#195) had checked out a
  commit that still pinned mediaserver's `shelfmark` v1.3.11; by the time it ran,
  the mediaserver run had already auto-reverted that pin on `main`. Its reconcile
  pass duly saw mediaserver "drifting", chased a pin main no longer wanted for the
  full budget, and went red — a second failure caused entirely by the first.
  The verify step now re-reads each stack's compose from `origin/main` and **skips**
  any stack whose intended state has moved on, with a `::warning::`. Whoever owns
  the newer state verifies it. Non-fatal if the fetch fails: it falls back to
  verifying the checkout, as before.
- **Runs get cancelled in a merge burst — that is GitHub, not a bug here.** The
  `concurrency: deploy-stacks` group holds exactly **one** pending run: merge two
  PRs back to back and the first pending run is cancelled *before any job starts*
  (it has zero jobs in the API — nothing to read in the log, and no webhook was
  fired). `cancel-in-progress: false` does not prevent this; it only protects the
  run that is already executing. The merge sweep in `renovate-pr-review.yml` now
  waits for each deploy to finish before merging the next, and the reconcile pass
  above catches whatever still slips through.
- **`github-runner` deploys on a deferred, unverified path (`DEFER_FIRE`).** Its
  container *is* the runner (and `EPHEMERAL=true`), so Portainer recreating it
  lands ~a minute later as `The runner has received a shutdown signal` / exit 143
  in whatever job is running by then — which killed the 2026-08-01 deploy and,
  once the convergence gate made the job sit through the whole pull, its own runs
  on 2026-08-19 and 2026-08-20 (both stacks deployed fine; both reported red).
  So its webhook is **not** fired inline with the other stacks. Pass 2 collects it
  into `deferred`, and the job's **last** step (`Fire deferred (self-hosting) stack
  webhooks`) fires it after every other stack is verified, then exits — the swap
  now lands on an idle runner.
  - Once Komodo owns the stack (`komodo/owned-stacks`), that step sends Komodo's
    `DeployStack` instead of the webhook, also without waiting. It checks once that the stack
    is idle, because Komodo drops an execute sent to a busy stack
    ([komodo-migration.md F16](komodo-migration.md)). With `komodo_dry_run` it only logs
    `dry run: would DeployStack`.
  - It is **never health-checked and never rolled back**: the check would have to
    outlive the container running it. That is the trade for deploying it at all.
  - The hazard it does *not* remove: the recreate still lands ~90s after the job
    ends, so a run queued right behind this one can still die with 143. The sweep
    in `renovate-pr-review.yml` still merges the `github-runner` PR **last**, and
    the reconcile pass picks up anything that pin-strands.
  - If a runner bump ever ships broken the symptom is that **no later run starts
    at all**. CI cannot recover a runner it cannot reach — revert the pin and bring
    it up by hand on the NAS (see [github-runner.md](../../services/github-runner.md) →
    Common failures for the command).
- **Manual catch-up: `workflow_dispatch`.** `gh workflow run deploy-stacks.yml`
  runs the reconcile pass alone; add `-f stacks="beszel homarr paperless"` to force
  specific ones. Redeploying by hand no longer needs an empty commit.
  - **Loop breaker: at most 2 auto-rollbacks per stack per 7 days.** Reverting a
    bump that Renovate immediately re-opens is a nightly revert/re-bump flap that
    nobody is watching, and every lap costs a red run. The rollback step counts
    prior `revert(deploy): roll back unhealthy stack(s): …` commits that touched
    that stack on `origin/main` in the last 7 days and refuses a third. When it
    fires, hold the pin in Renovate or fix the stack by hand — the bump is not a
    blip.
  - A dispatched or reconciled stack that comes up unhealthy is **never** rolled
    back: it did not come from this push, so there is no bad commit to revert —
    reverting would just undo whichever commit happens to be newest. The run goes
    red and says so instead. Only push-derived stacks are rollback candidates.
- **`-k` / self-signed cert.** Every call keeps `-k` because the certificate's SAN can
  never match the LAN IP, and pins the public key instead — see TLS above.
- **Runner down = no auto-deploy.** Webhook-only means a push won't deploy if the
  runner is offline. Fix the runner, then re-push or fire the webhook by hand:
  `curl -k -X POST https://192.168.178.111:31015/api/stacks/webhooks/<uuid>`.
- **Multi-commit pushes.** The workflow diffs `github.event.before..github.sha`
  (the whole pushed range), not `HEAD^..HEAD` — otherwise a push whose final commit
  touches only `docs/` would report "No stack folders changed" even though an earlier
  commit in the same push changed a stack. Needs `fetch-depth: 0` on checkout so the
  full range is available locally.
- **Which Portainer environment (endpoint) a stack deploys to.** Three environments
  live in one Portainer: **`3` = local** (NAS, `unix:///var/run/docker.sock`),
  **`4` = micro VPS** (a Portainer Agent over Tailscale, `tcp://100.64.0.12:9001`) and
  **`5` = A1** (Agent, `tcp://100.64.0.13:9001`). Routing is **by name**
  (`target_endpoint()` in `fire-webhooks.sh`): `micro-vps-*` → 4, `a1-vps-*` → 5,
  everything else → 3.
  - For an **existing** stack, redeploy fires its webhook (endpoint-independent) and
    the health check reads the stack's live `EndpointId` from `/api/stacks`, so it
    polls the *right* environment automatically regardless of name.
  - For a **new** stack, the **name prefix routes the create call**: anything meant
    for a VPS must carry its prefix, or it gets created on the NAS. Portainer's
    *server* clones the repo either way (the git Source is server-side); only the
    target agent differs.
- **New stack added later — auto-created.** Push a new `stacks/<name>/` folder and
  `deploy-stacks` **creates the stack in Portainer for you** (`POST
  /api/stacks/create/standalone/repository`, on the endpoint its name prefix routes
  to): GitOps from the repo, webhook enabled (a fresh UUID is pre-generated so
  subsequent pushes hit the normal redeploy path). Requires a write-scoped
  `PORTAINER_API_TOKEN`; the git credential comes from the Portainer Source
  (`GET /api/gitops/sources`), not from a repo variable.
  Then the same health check runs on that endpoint.
  - **A new stack that has vault env is NOT auto-created.** CI holds no age key, so the
    run fails with `'<name>' is NEW and its env lives in the vault` and names the fix:
    run `scripts/secrets.sh push <name>` from your workstation — that creates the stack
    with its env — then re-run `deploy-stacks` to health-check it. Only a new stack with
    **no** `secrets.enc/portainer-env/<name>.env.age` is created by CI, with empty env.
    Existing stacks are untouched by this: they redeploy through their webhook, which
    never reads env.
  - **CREATE_SKIP guardrail.** Some folders are never auto-created (they'd break
    or belong elsewhere): `github-runner` (runs this job — self-teardown),
    `portainer` (a TrueNAS app, not a stack), `micro-vps-agent`/`a1-vps-agent` (the
    transport for their own endpoint), and `authentik`/`npm` (auth + reverse proxy, too
    critical to spin up blind — `npm` stays listed although the stack is gone, so
    reverting its removal cannot recreate it unattended). The list is `CREATE_SKIP` at
    the top of `fire-webhooks.sh` — edit it there. A skipped-new stack logs a
    `::warning::`; create it by hand. (Other VPS stacks are **not** skipped — the name
    prefix routes them.)
  - **No auto-rollback for a brand-new stack.** Rollback restores a stack's
    *pre-push* files, but a new stack has none at `github.event.before`, so if it
    comes up unhealthy the workflow goes red — the
    half-broken stack stays in Portainer; tear it down or fix it by hand.
  - **Order note.** Push env before compose. `scripts/secrets.sh push <name>` applies
    the env (creating the stack if needed); the compose push then redeploys against it.
- **Existing stack, still no webhook.** A stack that *already* exists in Portainer
  but has no webhook enabled is skipped with a warning (enable it once: Stack →
  GitOps updates → Webhook). Only **absent** stacks are auto-created.
- **Adding the runner doesn't open any port** — it's outbound only.
- The `portainer` stack is unaffected (it's a TrueNAS app, not a Portainer stack).
- **Post-deploy health check.** After the webhooks fire, the workflow polls the
  Portainer API for each redeployed stack's containers **on that stack's endpoint**
  (3 = local, 4 = micro VPS, 5 = A1 — passed through as `<stack>=<endpoint>` pairs), ~4 min, and
  fails red if any is `unhealthy`/not-running. It assumes the
  Portainer **stack name == folder name** (the `com.docker.compose.project`
  label it filters on) and needs `jq` on the runner (the myoung34 image bundles
  it).
- **Convergence gate — the health check waits for the NEW containers first.** The
  webhook returns as soon as Portainer accepts it; the pull and recreate happen
  behind it and can take minutes. Health polling on its own therefore passes on
  the containers from the *previous* deploy — running, healthy, and completely
  untouched — so the run goes green for a deploy that has not happened yet. That
  is what PR #140 (mediaserver, 2026-08-16) hit: `OK: mediaserver healthy` a full
  minute before Portainer had pulled `shelfmark v1.3.9`, `questarr v1.4.2` and
  `postgres:18.6`. So each stack is now gated on convergence before its health is
  judged. Converged means all three of:
  1. no **running** container carries a `sha256:` digest the repo does not pin
     (same direction as the reconcile pass — a running digest we do not pin is by
     definition the old container),
  2. the container count is stable across one poll, and
  3. the count is at least the number of digest-pinned `image:` lines in the
     stack's compose file, so a half-recreated stack cannot look settled.

  Unpinned services (`:latest` with no digest) are skipped by the digest
  comparison and only ever push the real count above the floor, and `Exited (0)`
  one-shots are ignored for staleness so an old init container cannot block
  convergence forever.
- **The convergence budget is NO-PROGRESS, not wall-clock.** It used to be a flat
  10 min (`CONVERGE_TRIES=100` × `GAP=6`) and that is a cliff: whether it is
  correct depends on image size and uplink speed, so it is always either too tight
  or useless. On **2026-08-21** mediaserver's 1.5 GB `shelfmark` v1.3.11 pull hit a
  `Download failed, retrying (1/5): unexpected EOF` **9.5 minutes into the 10 minute
  budget**; the gate expired 70s later, the stack was declared unhealthy, and a
  perfectly good pin was auto-reverted. Raising the number only moves the cliff.
  Now each poll builds a progress fingerprint (`converge_state`): how many of the
  repo's pinned digests exist as images on the host, plus the container
  name→image set. Any change resets the clock; the gate gives up only after
  `CONVERGE_STALL` (240s) with **nothing at all** changing. `CONVERGE_MAX` (2700s)
  is a pure backstop so a crash-looping stack still terminates.
  - Cost: one extra `/docker/images/json` call per stack per 6s poll. Cheap on the
    LAN, and with pre-pull (below) convergence is normally seconds anyway.
- **Pre-pull — images are fetched BEFORE the webhook fires.** The fire step pulls
  each stack's pinned digests through Portainer's docker proxy
  (`POST /endpoints/{id}/docker/images/create`) and only then fires the webhook, so
  the redeploy has nothing left to download and the convergence gate measures
  *recreate* time instead of *download* time. That is what makes the gate's budget
  meaningful. It also turns an unpullable digest into a precise error at the moment
  it happens instead of a mystery convergence timeout ten minutes later.
  - Best-effort: a failed pre-pull only warns, because the redeploy can still pull
    the image itself. Public registries only — no `X-Registry-Auth` is sent.
  - **`DEFER_FIRE` stacks are deliberately NOT pre-pulled.** `github-runner`'s whole
    safety margin is the ~90s Portainer spends pulling after the final step fires
    its webhook; warm layers would collapse that and drop the container swap back
    onto the job's own cleanup.
- **"Did not converge" is NOT "unhealthy", and never rolls back.** `wait_converged`
  returns **2** for "the deploy never landed" and the health phase returns **1** for
  "the new containers are genuinely broken"; only **1** may reach the rollback
  machinery. A convergence failure is an *unknown* — almost always a slow or
  interrupted pull — and reverting on it destroys a good commit, fails the run
  twice, and leaves prod on the old image anyway. A stalled stack goes red, main is
  left untouched, and the next run's reconcile pass retries it for free.
- **Auto-rollback.** If a stack is **unhealthy** after the poll budget (positive
  evidence of breakage — *not* a convergence timeout, see above), the
  workflow restores **only that stack's** compose files to their pre-push
  (`github.event.before`) state, commits + pushes that to `main`, and re-fires
  that stack's Portainer webhook so prod pulls the restored files. Good bumps in
  the same push stay upgraded. The run still exits red for visibility. This keeps the
  review sweep's merges hands-off: a bad bump self-heals in minutes inside the
  05:00–06:00 window, and Renovate re-proposes it next cycle (the loop breaker above
  stops that turning into a nightly flap).
  - Requires `permissions: contents: write` on the workflow (set) **and** a token
    that can push past branch protection: the checkout uses the `ROLLBACK_TOKEN`
    secret (a repo admin's fine-grained PAT) and falls back to `GITHUB_TOKEN`, whose
    push the required `validate` check rejects — the run then goes red with a push
    error while prod stays on the bad bump.
  - The rollback step fires the webhook itself rather than relying on a second run,
    so the rolled-back state is **not** re-health-checked automatically — check
    Portainer. (It re-discovers webhooks from Portainer the same way the fire step
    does.) Because the push is made with a PAT it *would* re-trigger `deploy-stacks`;
    the `[skip ci]` in the rollback commit is what prevents a deploy→rollback loop —
    keep it.
- **Avoiding false rollbacks.** A rollback is only useful when the stack is
  genuinely broken. Two guards keep a *working* upgrade from being reverted:
  - **Clean `Exited (0)` is not "unhealthy".** Run-once / init containers exit 0
    by design; flagging them would roll back every deploy. A crash-loop
    (`restarting`) or nonzero exit is still caught.
  - **~4-min poll budget** (`TRIES=40`) so a slow-pulling/slow-starting image
    isn't still `health: starting` when the budget ends. This budget starts only
    once the stack has converged onto the repo's pins, so a long pull eats the
    convergence budget above, not this one.
  - **Missing-probe-tool false-unhealthy** (see the gotcha below). A base-image
    bump that removes `curl`/`wget` flips the container `unhealthy` even though
    the app works. The health check reads the container's last healthcheck-log
    line via the API proxy; if it matches `not found` / `no such file` /
    `executable file not found` / `not installed`, that container is logged as a
    `::warning::` and **not** counted as a failure — so it does not trigger a
    rollback or thrash the Renovate cycle. A genuine crash (nonzero exit,
    `restarting`) is unaffected and still rolls back. It's a heuristic on the log
    text; still audit the probe-tool table below when a base image in it bumps.
- **Pre-merge validation.** [`compose-validate.yml`](../../../.github/workflows/compose-validate.yml)
  schema-checks changed compose files on `pull_request` (GitHub-hosted runner,
  **never** the NAS runner). Its `validate` job is a required status check on
  `main`, so a broken compose file cannot be merged.

## Gotcha: healthcheck fails because the probe tool isn't in the image

Symptom: the post-deploy health check turns red and the container shows
`Up N minutes (unhealthy)`, **but the app works fine in the browser**. The app
is healthy — the *healthcheck command* is what's failing.

Cause: an HTTP-style healthcheck (`wget …/health` or `curl …`) only works if
that binary is baked into the image. Minimal images (scratch/distroless/
debian-slim) often ship **neither** `wget` nor `curl`. The browser hits `/`
(the app), the healthcheck hits a probe binary that doesn't exist, so Docker
flips the container `unhealthy` after `retries` fails. `compose-validate`
does **not** catch this — `docker compose config` never runs the command.

Confirm which it is — read the healthcheck log via the Portainer API proxy
(endpoint 3; over SSH, `sudo -n docker inspect <name>` shows the same):

```bash
curl -sk -H "X-API-Key: $PORTAINER_TOKEN" \
  "$PORTAINER_URL/api/endpoints/3/docker/containers/<name>/json" \
  | jq '.State.Health.Log[-1].Output'
# broken-probe tell: "wget: not found" / "curl: not found" / "no such file"
```

Real case (2026-07): an image was debian-slim → no `wget`, so
`wget -qO- …/health` logged `wget: not found`, `FailingStreak` in the
thousands. Fix was to **drop the healthcheck** (the image ships no HTTP client;
the deploy workflow still gates on `State==running`). Alternative if you want a real probe:
layer a static busybox onto the upstream image via a small multi-stage
Dockerfile and `busybox wget` against it.

**Healthchecks that depend on an in-image HTTP client** — audit these whenever
their base image is bumped (a base change can remove the tool):

| Stack | Probe | Tool must exist in image |
| --- | --- | --- |
| `paperless` (webserver) | `curl …:8000` | curl |
| `files` | `curl …:30052/health` | curl |
| `homarr` | `wget --spider …:7575` | wget |
| `romm` | `wget …:8080/api/heartbeat` | wget (busybox) |
| `mealie` | `python3 -c urllib…` | python3 |

Self-contained probes (tool bundled with the service, not affected by this
class of failure): `pg_isready` (postgres), `redis-cli` (redis/valkey),
`extra/healthcheck` (uptime-kuma), `/gluetun-entrypoint healthcheck` (gluetun).

- **Not this class: `gluetun` unhealthy.** gluetun's probe is a bundled binary,
  so `unhealthy` there is a **genuine** connectivity failure, not a missing tool.
  Read the tunnel-vs-DNS distinction from `.State.Health.Log` / container logs:
  a source IP like `10.2.0.2` on the DNS error means the WireGuard handshake
  **succeeded** (that's the Proton-assigned tunnel IP) and the fault is DNS, not
  the tunnel. Seen 2026-07: `[dns] TLS handshake with 1.0.0.1:853 … connection
  reset by peer` — ProtonVPN blocks third-party DNS-over-TLS, so gluetun's
  default `DOT=on` (Cloudflare) failed, DNS died, the healthcheck's domain
  lookups timed out, and gluetun restart-looped the tunnel every ~6s. Fix:
  `DOT=off` in the gluetun env so it uses Proton's own resolver (`10.2.0.1`).
  An `arr` redeploy red-flags while this is broken.
