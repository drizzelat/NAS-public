# Portainer app deploy (repo → TrueNAS middleware)

> **Retired 2026-09-17.** `deploy-portainer-app.yml` was deleted in SVC-2 Phase 3: its weekly canary
> redeployed a Komodo-owned stack ([komodo-migration.md F26](komodo-migration.md#f26--portainers-canary-redeployed-a-komodo-owned-stack)),
> and Portainer itself is being removed. `NAS_SSH_KEY` went with it. Kept as a record of how it worked.

How `stacks/portainer/docker-compose.yml` became the source of truth for Portainer
itself, and how to upgrade or recover the control plane.

## Why this exists

Portainer deploys every other stack. It cannot deploy itself, so before this the
repo's Portainer compose file was documentation only: pushes to
`stacks/portainer/` hit `CREATE_SKIP` in `deploy-stacks.yml`, warned, and did
nothing. Every real change was hand-made in the TrueNAS UI and never recorded.

That cost 16 days of silently broken secret sync. Portainer 2.39.5 built the
clone credentials for `PUT /api/stacks/{id}/git/redeploy` only inside
`if payload.RepositoryAuthentication`, so the env-push path — which sent
`false` — made it clone this **private** repo anonymously: GitHub 401 → HTTP 500,
returned in ~190 ms, before any deployment, so Portainer logged nothing. Nothing
exercised that call between pushes, so nothing noticed.

## How it works

[`deploy-portainer-app.yml`](../../../.github/workflows/deploy-portainer-app.yml)
deploys Portainer through the **TrueNAS middleware** instead of through Portainer.

Portainer is a TrueNAS *custom app*, and `midclt call app.config portainer`
returns exactly the `{services, volumes}` dict this repo's compose file holds —
they are the same document, so the repo file can be applied verbatim.

| Step | What it does |
| ---- | ------------ |
| 1 | Refuse a compose whose image is not `tag@sha256:` — the control plane never runs a floating tag |
| 2 | Capture the live app config as **last-known-good** *before* changing anything |
| 3 | No-op guard: recursively key-sorted JSON compare, repo vs live. Equal → exit, since applying recreates the container |
| 4 | Apply: `midclt call -j app.update portainer '{"custom_compose_config_string": …}'` |
| 5 | Wait for `GET /api/system/status` (needs no auth) to report a version |
| 6 | **Canary**: replay `PUT /api/stacks/{id}/git/redeploy` against one stateless stack, with its stored env unchanged and its git credential replayed |
| 7 | Any failure in 4–6 → re-apply last-known-good, wait again, fail the run |

Two properties matter most:

- **Rollback does not need Portainer.** It goes back over the same middleware, so
  a compose file that leaves Portainer dead is still recoverable by CI.
- **The canary tests the path that broke.** A version that regresses the redeploy
  API is reverted inside the same run, instead of surfacing weeks later.

The runner survives all of this: Portainer is only a control plane, and Docker
keeps every container — including `stacks/github-runner`, which runs the job —
alive while Portainer is down.

### Gotchas confirmed on TrueNAS SCALE 25.04.2

- `custom_compose_config_string` is **top-level** in `app.update`'s second
  argument, *not* under `values`. `app.update` is a job → `midclt call -j`.
- Rollback uses `custom_compose_config` (a dict) so the captured config needs no
  YAML round-trip.
- The repo YAML is parsed **on the NAS** (`python3` + `yaml` ship with TrueNAS);
  the runner image is not guaranteed to have a YAML parser.
- The apply payload is piped over stdin to a remote temp file rather than
  inlined, so the JSON never has to survive two layers of shell quoting.

## Upgrading Portainer

`portainer-ee` publishes the **LTS** line on `latest`/`lts` and the **short-term**
line on `sts`. Pinning `latest@sha256:` therefore froze this NAS on 2.39.5 (pushed
2026-07-13) *and* hid every later release from Renovate, since the tag's digest
never moved. The compose file now pins an explicit version.

1. Renovate opens the bump PR. It is labelled `needs-manual-review` +
   `control-plane` and is on `MERGE_SKIP` in `renovate-pr-review.yml`, so the
   05:00–06:00 sweep will **never** merge it.
2. Read the release notes. Decide LTS vs STS deliberately — STS gets fixes first
   but has a shorter support tail, and this is the control plane.
3. Merge by hand. `deploy-portainer-app.yml` applies it, health-polls, canaries
   the redeploy API, and rolls back if that call is broken.
4. If it rolled back: the run's log names the HTTP status and response body.

Never press **Update** in the TrueNAS or Portainer UI. It writes to a place git
never sees; the nightly health check reports the repo-vs-live drift, and the next
deploy of `stacks/portainer/` or image-guard repair reverts it.

## Recovery

**The workflow failed and rolled back.** Portainer is on the previous config;
read the log for the reason. Nothing else to do.

**The rollback itself failed** (`ROLLBACK CALL FAILED`, or Portainer never came
back). TrueNAS UI → **Apps** → `portainer` → edit the custom app back by hand, or
re-apply from a shell on the NAS:

```bash
midclt call app.config portainer            # look at what is deployed now
midclt call -j app.update portainer "$(jq -n --rawfile c docker-compose.yml \
  '{custom_compose_config_string:$c}')"     # re-apply a known-good file
```

Running containers are unaffected while Portainer is down — Docker runs
independently. You lose the management UI and webhook deploys, nothing else.

**Verify the redeploy API by itself**, without changing the version: run the
workflow with `canary_only: true`. Use this after any hand-made Portainer change.

This also runs on its own every **Sunday 06:00 UTC**. A scheduled run is *forced*
canary-only — it never applies the compose, because reconciling drift by
recreating Portainer with nobody watching is not something a cron should decide.
Drift is the nightly health check's job to *report*; the schedule only probes the
write path. That division matters: `nas-health-check` is read-only by design and
holds no write-scoped credentials, so it can never make this `PUT` itself, which
is precisely how a broken redeploy endpoint stayed invisible for 16 days.

## Repo variables / secrets

| Name | Kind | Default | Purpose |
| ---- | ---- | ------- | ------- |
| `NAS_SSH_KEY` | secret | — | `truenas_ed25519` from the age vault. Used for a **mutation** here, unlike the read-only health check |
| `PORTAINER_API_TOKEN` | secret | — | Write-scoped; the canary calls the redeploy endpoint |
| `PORTAINER_URL` | var | — | e.g. `https://192.168.178.111:31015` |
| `NAS_SSH_HOST` | var | `192.168.178.111` | Overrides the host from `docs/network.md` |
| `NAS_SSH_USER` | var | `truenas_admin` | Overrides the user from `docs/network.md` |
| `PORTAINER_CANARY_STACK` | var | `files` | Stack the canary redeploys. Must be stateless and cheap — it is recreated on every Portainer version change **and weekly** |

## Related

- [Secret sync](secret-sync.md) — the `scripts/secrets.sh push` path the canary protects
- [Per-stack webhook deploy](portainer-webhook-deploy.md) — how the *other* stacks deploy
- [Docker image prune + Portainer guard](docker-image-prune.md) — `portainer-image-guard.sh` re-pulls the **repo's** image string, which is why repo/live drift is a health-check FAIL
- [`docs/services/portainer.md`](../../services/portainer.md)

## Last updated

2026-09-11
