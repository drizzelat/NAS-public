# Service: File Browser

> **Archived 2026-09-09.** The `filebrowser` stack was deleted after
> [files](../services/files.md) (FileBrowser Quantum) took `files.example.com`; upstream
> [filebrowser/filebrowser](https://github.com/filebrowser/filebrowser) was archived 2026-09-01.
> Nothing here describes anything running. The data is still on disk at `/mnt/apps/filebrowser`
> (config + the old SQLite DB) as rollback material. How and why:
> [migration runbook](../runbooks/setup-operations/filebrowser-to-quantum.md).

## Overview

File Browser provides a web UI for browsing, uploading, downloading, and managing files on the NAS. It is configured to use Authentik for authentication via the proxy header method.

## Stack

- **Stack folder:** `stacks/filebrowser/`
- **Compose file:** `stacks/filebrowser/docker-compose.yml`

## Access

| Field | Value                           |
| ----- | ------------------------------- |
| URL   | `https://files.example.com`   |
| Port  | 30051                           |
| Auth  | Authentik proxy (header `X-authentik-username`) |

## Volumes / data

| Container path | Host path              | Purpose              |
| -------------- | ---------------------- | -------------------- |
| `/config`      | `/mnt/apps/filebrowser`| Config & database    |
| `/data`        | `/mnt/data/smb_share`  | Files served via UI  |

## Environment variables

| Variable         | Description                                 |
| ---------------- | ------------------------------------------- |
| `FB_DATABASE`    | Path to the SQLite DB inside the container  |
| `FB_PORT`        | Port the server listens on (30051)          |
| `FB_ROOT`        | Root data directory shown to users          |
| `FB_AUTH_METHOD` | Set to `proxy` — delegates auth to Authentik|
| `FB_AUTH_HEADER` | Header carrying the username from Authentik |
| `PUID` / `PGID` / `UID` / `GID` | Run as TrueNAS apps user (568) |

## Dependencies

- Authentik (for proxy authentication — the `X-authentik-username` header must be injected by nginx proxy manager + Authentik outpost).

## Notes

- Auth is completely delegated to Authentik. Without the proxy header, logins will fail.
- Runs as UID/GID 568 (TrueNAS default apps user) to match filesystem permissions on `/mnt/data/smb_share`.

## First-time UI setup

Auth is **fully delegated to Authentik** (proxy header `X-authentik-username`) — there is no local login form. Prerequisites: the Authentik proxy provider and its Caddy vhost must be working ([authentik](../services/authentik.md), [caddy](../services/caddy.md)).

1. **First login = first user** — browse to `https://files.example.com`. Authentik authenticates you and File Browser auto-creates a user from the header. The **first** such user should be the admin.
2. **Make sure that user is admin** — if the auto-created user lacks admin rights, grant them via the console: Portainer → `filebrowser` container → Console → `filebrowser users update <name> --perm.admin` (DB at `FB_DATABASE`). Without an admin you can't change global settings.
3. **Global settings** — Settings → **Global Settings**: set the default user **scope/root**, default permissions, and disable the built-in signup/auth (proxy handles it).
4. **Branding (optional)** — Settings → Branding: name, logo.
5. **Per-user scopes** — Settings → Users: for each Authentik user, set the folder scope under `/data` (`/mnt/data/smb_share`) and permissions.
6. **Verify permissions** — confirm files are readable/writable; the container must run as UID/GID **568** to match `smb_share` ownership.

## Operations

> Restart/redeploy go through **Portainer**, not host `docker` — the `truenas_admin` SSH user has no Docker socket access. Manual webhook fire: `curl -k -X POST https://192.168.178.111:31015/api/stacks/webhooks/<uuid>` (UUID from `scripts/portainer-migrate/read-webhooks.ps1`).

### Restart / redeploy

- Portainer → Stacks → `filebrowser` → **Restart** or **Pull and redeploy**.
- Or push to `stacks/filebrowser/` → runner fires the stack webhook ([webhook runbook](../runbooks/setup-operations/portainer-webhook-deploy.md)).

### Upgrade

- **Manual.** Pinned to a fixed `filebrowser/filebrowser` `tag@sha256:…` (exact version in the compose file). Bump: new tag → read digest → edit `image:` → commit/PR → redeploy.

### Restore from backup

1. Stop the `filebrowser` stack in Portainer.
2. Restore `apps/filebrowser` (config + SQLite DB: users, shares, settings) from a ZFS snapshot of `apps` or from Hetzner.
3. Start the stack. The **served files** under `/mnt/data/smb_share` are restored by the `data/smb_share` snapshot/sync, not by this stack.

### Common failures

- **All logins fail / 500** → auth is fully delegated to Authentik via the `X-authentik-username` proxy header. If Authentik **or** the NPM outpost is down, no header arrives → no login. Fix Authentik/NPM first ([cert/DNS/proxy runbook](../runbooks/incident-response/cert-dns-proxy-outage.md)).
- **Permission denied browsing files** → container must run as UID/GID 568 to match `/mnt/data/smb_share` ownership.

## Last updated

2026-06-29
