# Service: Immich

## Overview

Immich is a self-hosted photo and video backup and gallery solution. It includes machine learning features (facial recognition, object detection) and a mobile app for automatic photo uploads.

## Stack

- **Stack folder:** `stacks/immich/`
- **Compose file:** `stacks/immich/docker-compose.yml`
- **Deploy:** Komodo Stack `immich` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                                                               |
| ----- | ------------------------------------------------------------------- |
| URL   | `https://immich.example.com`                                      |
| Port  | 30041                                                               |
| Auth  | Authentik OAuth/OIDC (native connector). Local password login works on LAN/tailnet only — it is `403`ed at the public edge |

## Volumes / data

| Container path                     | Host path            | Purpose                          |
| ---------------------------------- | -------------------- | -------------------------------- |
| `/data`                            | `/mnt/data/immich`   | Photo/video library              |
| `/var/lib/postgresql` (`pgvecto` service) | `/mnt/apps/immich` | Postgres 18 + VectorChord database (datadir under `18/docker`) |

## Environment variables

Kept in the vault (`scripts/secrets.sh edit immich`); `scripts/secrets.sh push immich` writes them to the Komodo Variables `IMMICH__<KEY>` and deploys the stack through Komodo:

| Variable      | Description                        |
| ------------- | ---------------------------------- |
| `POSTGRES_PW` | Password for the Immich Postgres DB|
| `REDIS_PW`    | Password for the Valkey/Redis cache|

## Dependencies

- Internal PostgreSQL + VectorChord container, compose service `pgvecto` (vector search for ML features)
- `proxy_immich` (external) — defined by the `caddy` stack
- Internal Valkey (Redis-compatible) cache
- Internal machine-learning container
- `/dev/dri` device pass-through for hardware-accelerated transcoding/ML inference

## Notes

- **Public login is Authentik-only.** Caddy's public `:8443` site block returns `403` for
  `POST /api/auth/login` and `/api/auth/admin-sign-up`, the same pattern
  [jellyfin](jellyfin.md) uses. `/api/oauth/*` is not matched, so the web **and** the mobile app
  still log in through Authentik, and anonymous `/share/` links are untouched. LAN/tailnet `:443`
  keeps native password login as break-glass. See [caddy.md](caddy.md) and
  [network.md → Access control](../network.md#access-control-who-can-reach-each-subdomain).
- **Who may log in through OAuth is the Authentik `nas-users` binding** (since 2026-09-16) — see
  [authentik.md → Application access](authentik.md#application-access-the-login-allowlist).
- Uses the custom `ghcr.io/immich-app/postgres` image (**Postgres 18** + pgvecto/VectorChord extension, bespoke `18-vectorchordX.Y.Z` tag — exact pin in the compose file) — do not swap for a plain Postgres image.
- **No init containers.** The TrueNAS-import leftovers `pgvecto_upgrade` (a Postgres *major*-version upgrade helper) and `permissions` (a `root` volume-chown pass) were removed — both ran on every deploy, and an unattended data-mutating Postgres upgrade in the normal deploy path is a data-loss path. A Postgres major bump is now a deliberate manual step: [postgres-major-upgrade runbook](../runbooks/setup-operations/postgres-major-upgrade.md#immich-pgvecto--vectorchord).
- **Immich's own schema migrations** still run automatically inside `immich-server` at startup — that is unrelated to the removed helper.
- **Volume ownership is no longer fixed at boot.** The named volumes (`cli-temp-storage`, `ml-cache`, `redis-data`) are already `568:568` on disk. If they are ever recreated from scratch (disaster recovery, `docker volume rm`), Docker makes them `root:root` and the containers — which run as `568:568` — cannot write. Chown them by hand after any recreate; see Restore from backup below.
- Hardware transcoding via Intel iGPU requires `/dev/dri` and group IDs 44 (video) and 107 (render) added to the container.
- Machine-learning container has no exposed port — it is only reachable internally via `http://machine-learning:32002`.

## First-time UI setup

After the stack is up, do this in the Immich web UI:

1. **Create the owner** — first visit to `https://immich.example.com` shows the admin registration form. Create the owner (admin) account. (No public sign-up after this.)
2. **Admin → Settings → General** — set the **External domain** to `https://immich.example.com` so share links and the mobile app get correct URLs.
3. **OAuth (Authentik)** — Admin → Settings → **OAuth**: paste the **Issuer URL / Client ID / Client Secret** from the Authentik OIDC provider ([authentik doc](authentik.md)), set a button label, enable **auto-register**. Save, then test the "Login with Authentik" button in a private window before relying on it.
4. **Lock down local login** — the public edge already `403`s the password endpoint, so this step
   is now cosmetic: Settings → Authentication → disable password login hides the form that would
   only 403 anyway. **Leave the local admin password set** — it is the LAN/tailnet break-glass for
   an Authentik outage.
5. **Storage template** — Settings → **Storage Template**: enable and pick a folder layout before importing photos (re-running it on a large library is slow).
6. **Machine learning** — Settings → confirm the ML server URL `http://machine-learning:32002` and enable facial recognition / smart search as wanted.
7. **Mobile app** — install the app, point it at `https://immich.example.com`, log in (via Authentik), enable **background backup** for the camera roll.

## Smart Search CLIP model

Smart Search embeds photos with a CLIP model so you can search by natural-language text.
The **default model is English-only** — German queries degrade silently. This setup searches
in **both German and English**, so it uses a language-flexible model.

**Chosen model: `ViT-B-16-SigLIP2__webli`**

- **Why this one:** SigLIP2/XLM models understand the query *regardless* of the UI language
  setting, so mixed German + English search works without toggling anything. (NLLB models give
  higher single-language recall but expect the query to match the language set in user settings —
  wrong fit for mixed search.)
- **Why not a bigger model:** the NAS is an **N100 with no discrete GPU** ([hardware](../hardware.md)),
  so CLIP inference runs **CPU-only**. Large models (`ViT-SO400M-16-SigLIP2-384__webli` ~7G,
  `nllb-clip-large-siglip__mrl` ~4.2G) are both too heavy for the 4G ML memory cap **and** too slow
  per query on the N100 CPU — RAM is not the real ceiling, CPU is. `ViT-B-16-SigLIP2__webli` is
  **~1.45G**, fits the existing cap, and is fast enough on CPU.
- A large model would only be viable by switching the ML container to the **`-openvino`** image
  (iGPU inference) — but that contends with Jellyfin QuickSync transcode. Not worth it for
  household photo search; revisit only if search quality proves inadequate.

### How to set / change it

1. Immich → **Admin → Settings → Machine Learning → Smart Search** → set model name to
   `ViT-B-16-SigLIP2__webli`. Save. The ML container downloads it on next job.
2. **Re-index required:** changing the model invalidates existing embeddings. Run **Admin → Jobs →
   Smart Search → All** to re-embed the whole library. On the N100 CPU this is slow (~137G library)
   — schedule off-peak / overnight.
3. Confirm a German and an English query both return sensible results before considering it done.

## Operations

> Restart/redeploy go through **Komodo** (Stack `immich`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `immich` → **Deploy** (or **Restart**).
- Or push to `stacks/immich/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Server/ML, the custom VectorChord Postgres and Valkey are all `tag@sha256:digest`-pinned (exact versions in the compose file). Renovate opens the PRs: server + ML go through the review sweep (their **major** bumps are labelled `needs-manual-review`); the Postgres image and Valkey are on the sweep's `MERGE_SKIP_IMAGES` and are merged by hand.
- **Read Immich release notes before every bump** — Immich ships frequent breaking DB migrations, applied by `immich-server` itself at startup.
- **A Postgres major bump is not a deploy.** The `18-vectorchordX.Y.Z` image's *major* only moves by hand via the [postgres-major-upgrade runbook](../runbooks/setup-operations/postgres-major-upgrade.md#immich-pgvecto--vectorchord). Renovate only follows that image by digest (its tag updates are disabled in `renovate.json`), so it never crosses a major.
- **Do not swap the custom Postgres image** for plain Postgres — the vector extension would be missing.

### Restore from backup

1. Stop the `immich` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/immich` (Postgres + pgvecto DB) and `data/immich` (photo/video library, ~137G — has its own daily snapshot, 14-day retention) from a ZFS snapshot or from Hetzner.
3. **If the named volumes were recreated**, restore their ownership before starting the stack — nothing does this automatically any more:

   ```sh
   for v in immich_cli-temp-storage immich_ml-cache immich_redis-data; do
     sudo chown -R 568:568 "$(sudo docker volume inspect -f '{{.Mountpoint}}' "$v")"
   done
   ```

4. **Preferred DB path:** load the logical dump into `immich-pgvecto-1` — and only into the **same pgvecto/VectorChord image** (the dump references the vector extension). See [postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md). After a DB restore, run Immich's library/thumbnail jobs.
5. Start the stack.

### Common failures

- **DB won't start / "extension not found"** → wrong Postgres image; must be the pgvecto/VectorChord one.
- **No hardware transcode or ML acceleration** → `/dev/dri` passthrough + group IDs 44 (video) / 107 (render).
- **ML errors but no obvious endpoint** → machine-learning has no exposed port; reachable only internally at `http://machine-learning:32002`.
- **Public login fails** → Immich is public via its native Authentik OAuth/OIDC connector; if Authentik is down, OIDC login fails (local accounts are the fallback).

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
