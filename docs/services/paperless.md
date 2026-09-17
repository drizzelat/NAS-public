# Service: Paperless-ngx

## Overview

Paperless-ngx is a document management system that transforms your physical documents into a searchable online archive.

## Stack

- **Stack folder:** `stacks/paperless/`
- **Compose file:** `stacks/paperless/docker-compose.yml`
- **Deploy:** Komodo Stack `paperless` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                             |
| ----- | --------------------------------- |
| URL   | `https://paperless.example.com` |
| Port  | 8000                              |
| Auth  | Native (Paperless users)          |

## Volumes / data

| Container path                  | Host path                     | Purpose                          |
| ------------------------------- | ----------------------------- | -------------------------------- |
| `/usr/src/paperless/data`       | `/mnt/apps/paperless/data`    | Paperless internal data          |
| `/usr/src/paperless/media`      | `/mnt/data/paperless/media`   | Stored documents/PDFs            |
| `/usr/src/paperless/export`     | `/mnt/data/paperless/export`  | Export directory                 |
| `/usr/src/paperless/consume`    | `/mnt/data/paperless/consume` | Drop folder for auto-ingestion   |
| `/var/lib/postgresql` (db)      | `/mnt/apps/paperless/db`      | Postgres database (PG18 versioned datadir; data under `db/18/docker`) |
| `/data` (redis)                 | `/mnt/apps/paperless/redis`   | Redis broker data                |

## Environment variables

Kept in the vault (`scripts/secrets.sh edit paperless`); `scripts/secrets.sh push paperless` writes them to the Komodo Variables `PAPERLESS__<KEY>` and deploys the stack through Komodo:

| Variable               | Description                                          |
| ---------------------- | ---------------------------------------------------- |
| `PAPERLESS_DB_PW`      | Password for the Paperless Postgres DB (`db` + app)  |
| `PAPERLESS_SECRET_KEY` | Django secret key — **mandatory since 3.0** (below)  |

`PAPERLESS_SECRET_KEY` is required from paperless-ngx **3.0** onwards: the container
aborts at startup with `ImproperlyConfigured: PAPERLESS_SECRET_KEY is not set or is
the default 'change-me' value` if it is missing. Generate one with
`python3 -c "import secrets; print(secrets.token_urlsafe(64))"`. Changing it later
only invalidates existing sessions (users must log in again); no stored data depends
on it.

`PAPERLESS_URL` and `PAPERLESS_CSRF_TRUSTED_ORIGINS` are set directly in the
compose file to `https://paperless.example.com`. Both are **required** because
Paperless runs behind the reverse proxy — without them Django rejects login POSTs
with `CSRF verification failed. Request aborted.` The webserver publishes no host
port, so it is only reachable through the proxy; there is no direct-IP bypass.

## Notes

- Drop files into `/mnt/data/paperless/consume` to have them automatically imported and processed.
- The `media`, `export`, and `consume` folders are on the `data` pool, as they contain bulk user files.
- The `db`, `data`, and `redis` folders are on the `apps` NVMe pool for fast database performance.
- The first user is created from the console with the Django `createsuperuser` command (`docker exec -it paperless python manage.py createsuperuser`) — there is no web sign-up.

## First-time UI setup

Paperless has **no web sign-up** — create the first user from the console, then configure in the UI:

1. **Superuser** — over SSH on the NAS, `sudo docker exec -it paperless python manage.py createsuperuser`. Then log in at `https://paperless.example.com`.
2. **Settings** — confirm timezone/date format and language.
3. **Taxonomy** — create **Tags**, **Correspondents**, **Document types**, and **Storage paths** for how documents should be filed.
4. **Auto-matching** — on each tag/correspondent set a matching algorithm (e.g. *Auto* or keyword) so new documents get classified on ingestion.
5. **Mail rules (optional)** — Admin (`/admin/`) → Mail accounts + Mail rules to pull documents from an inbox.
6. **Consume folder** — drop files into `/mnt/data/paperless/consume`; they import automatically. Verify one test document flows through.
7. **More users (optional)** — Admin → Users/Groups for additional logins and permissions.

## AI auto-tagging — removed 2026-08-21

**Status: removed.** The `paperless-ai` sidecar used to post the full OCR text of every
processed document to `https://generativelanguage.googleapis.com/v1beta/openai/` — Google's
Gemini endpoint. That archive holds contracts, invoices, medical and tax records.

This was never a vulnerability; it was the one place where the estate's posture was
inconsistent. Everything else here is aggressively self-hosted and privacy-first, and this
single env var routed the most sensitive dataset in the house to a third party
([SVC-4](../architecture-review-2026-08-20.md#svc-4--paperless-ai-sends-documents-to-google)).

Removed rather than repointed at a local Ollama: the N100 has no discrete GPU (see
[hardware.md](../hardware.md)), so local inference would be slow, and **paperless-ngx's native
matching rules cover most of what the sidecar did**.

### What replaces it

Paperless-ngx assigns tags, correspondents and document types itself, with no LLM:

- **Settings → Tags / Correspondents / Document types**, each with a *matching algorithm* —
  `Any word`, `All words`, `Exact match`, `Regular expression`, or `Auto` (which trains on
  documents you have already classified).
- **`Auto` improves as you correct it.** The first few dozen documents need manual tagging;
  after that it is accurate for recurring correspondents, which is the household case.
- **Mail rules** (Admin → Mail accounts / Mail rules) can tag on ingest by sender or subject.

### Leftovers

- **`/mnt/apps/paperless/ai` was deleted 2026-08-22.** It held the sidecar's state and, more to
  the point, a **plaintext copy of the Gemini API key** in `.env` — removing it took the last live
  plaintext copy off disk. It survives in `apps/paperless@auto-*` snapshots for three days.
- **Paperless API token rotated 2026-08-22.** The old DRF token for `stefan` was deleted and a new
  one issued; nothing consumes it now. Read the current value in Settings if you ever need it.
- **The sidecar's Gemini API key still needs revoking in Google AI Studio / Cloud Console** —
  removing a key from the vault and from disk does not invalidate it. Nothing here uses it any
  more.

  > **Revoke the key that starts `AQ.Ab8` (53 chars) — not the one that starts `AIzaSy` (39
  > chars).** The `AIzaSy` key is Mealie's and is live; deleting it breaks Mealie's URL, image and
  > video recipe import (see [mealie.md](mealie.md#ai-recipe-parsing-gemini)).

  Both services talked to the same Gemini endpoint, so it is easy to assume one shared key —
  they are two separate keys, confirmed by comparing SHA-256 of both values on 2026-08-22. An
  earlier version of this doc got this wrong in both directions: first claiming the key was
  "reused from Mealie", then claiming Mealie had no AI configuration at all. Mealie's key lives
  in its own Postgres (`ai_providers.api_key`), set through the Mealie UI — not in a stack env
  var and not in the vault.
- **The NPM proxy host for the sidecar UI was deleted 2026-08-22**, by hand in the NPM UI — see
  [GAP-1](../architecture-review-2026-08-20.md#gap-1--npm-and-authentik-config-is-click-ops).

## Operations

> Restart/redeploy go through **Komodo** (Stack `paperless`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `paperless` → **Deploy** (or **Restart**).
- Or push to `stacks/paperless/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- The app, `db` (**Postgres 18**) and `redis` (**Redis 8**) are all pinned `tag@sha256:…` (exact versions in the compose file). Renovate opens the PRs. The app goes through the review sweep, and its **major** bumps are labelled `needs-manual-review` (they can require migrations); Postgres and Redis are on the sweep's `MERGE_SKIP_IMAGES` and are merged by hand. Postgres migrated 15→18 on 2026-07-02 (versioned datadir) — see [postgres-major-upgrade runbook](../runbooks/setup-operations/postgres-major-upgrade.md).

### Restore from backup

1. Stop the `paperless` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/paperless/{data,db,redis}` and `data/paperless/{media,export,consume}` (the **`media` dir holds the actual document files** on the data pool, daily snapshot) from a ZFS snapshot or from Hetzner.
3. **Preferred DB path:** load the logical dump into `paperless-db` — see [postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md).
4. Start the stack.

### Common failures

- **Documents not ingested** → check `/mnt/data/paperless/consume` permissions and that the consumer is running; drop files there to trigger import.
- **DB auth failure** → `PAPERLESS_DB_PW` must match between the `db` and app containers.
- **`CSRF verification failed. Request aborted.`** on login → `PAPERLESS_URL` /
  `PAPERLESS_CSRF_TRUSTED_ORIGINS` missing or not matching the proxied URL
  (`https://paperless.example.com`). Set both and redeploy.
- **Need a superuser** → run the Django `createsuperuser` command in the `paperless` container (`sudo docker exec -it paperless python manage.py createsuperuser` over SSH on the NAS).

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
