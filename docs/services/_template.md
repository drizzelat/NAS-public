# Service: <name>

## Overview

_(What does this service do? One paragraph.)_

## Stack

- **Stack folder:** `stacks/<name>/`
- **Compose file:** `stacks/<name>/docker-compose.yml`

## Access

| | |
|---|---|
| URL | _(e.g. `https://<name>.example.com` — through Caddy, no host port)_ |
| Port | _(port number)_ |
| Auth | _(login method: local user, SSO, API key, none)_ |

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| _(fill in)_ | _(fill in)_ | _(fill in)_ |

## Environment variables

List any env vars that need to be set as Komodo Variables from the vault (do not put secret values here).

| Variable | Description |
|---|---|
| _(fill in)_ | _(fill in)_ |

## Dependencies

_(Other services this depends on, e.g. a database container, a shared Docker network.)_

## Notes

_(Anything unusual, quirks, upgrade warnings, etc.)_

## Operations

> Restart/redeploy go through **Komodo** (Stack `<name>`), which deploys from `komodo/resources.toml`. Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

_(Komodo → Stacks → `<name>` → **Restart** (bounce) or **Deploy** (pull and recreate). Or push to `stacks/<name>/` → the runner deploys it through Komodo — see the [deploy-stacks runbook](../runbooks/setup-operations/deploy-stacks.md).)_

### Upgrade

_(Every image is pinned `tag@sha256:digest`. Renovate opens the bump PR, [renovate-pr-review](../runbooks/setup-operations/renovate-pr-review.md) reviews it, and the 05:00–06:00 sweep merges it if cleared — except images on `MERGE_SKIP_IMAGES` (databases, caches, Authentik, the Caddy build), which are merged by hand. Note breaking-change / migration warnings; rollback = revert the commit + redeploy.)_

### Restore from backup

_(Stop stack → restore which dataset(s) from local ZFS snapshot (fast) or Hetzner (offsite) → start. Postgres services: prefer the logical dump — see [postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md). General restore steps: [backup runbook](../runbooks/backup-restore/backup.md).)_

### Common failures

_(Known quirks, what breaks, symptoms → fix.)_

## Last updated

_(YYYY-MM-DD)_
