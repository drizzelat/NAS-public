# Service: Files (FileBrowser Quantum)

## Overview

Web UI for browsing, uploading, downloading and sharing the SMB share. Replaces
[File Browser](../archive/filebrowser.md), whose upstream repo was archived on 2026-09-01 (no further
releases, bug fixes or security fixes). This is **FileBrowser Quantum**
([gtsteffaniak/filebrowser](https://github.com/gtsteffaniak/filebrowser)), the maintained fork.

Three things drove the choice: native OIDC (so Authentik is the login, not a proxy header),
share links with expiry/password/anonymous access, and **upload shares** — a link that lets
someone drop files in without an account. It serves a plain filesystem, so `/mnt/data/smb_share`
is used as-is; nothing is imported into an app-owned store and SMB keeps working unchanged.

## Stack

- **Stack folder:** `stacks/files/`
- **Compose file:** `stacks/files/docker-compose.yml`
- **Deploy:** Komodo Stack `files` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.
- **App config:** `stacks/files/config.yaml` — read by the container from Komodo's clone on the NAS

## Access

| Field | Value |
| ----- | ----- |
| URL | `https://files.example.com` |
| Port | 30052, container-internal only — reached through Caddy over `proxy_files` |
| Auth | Authentik OIDC (`files` application). No password login. |

Caddy proxies **straight to the container**, not through the Authentik outpost. Quantum runs the
OIDC dance itself, so public share and upload links resolve without punching `skip_path_regex`
holes in a proxy provider — which is exactly what the old filebrowser setup had to do.

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/config` (ro) | `/mnt/apps/komodo/repos/nas/stacks/files` | `config.yaml`, read-only from Komodo's clone. `post_deploy` checks the mount matches the clone (komodo-migration.md F28) |
| `/state` | `/mnt/apps/files` | SQLite DB (users, shares, index) + preview cache |
| `/srv/smb_share` | `/mnt/data/smb_share` | The files themselves |

`/config` is the **directory**, not the file: git replaces `config.yaml`'s inode on pull and a
single-file bind mount would pin the old one forever (same reason as [caddy](caddy.md)).

> Quantum merges every sibling file matching `*-config.yaml` into the main config. Never add a
> file with that suffix to `stacks/files/`.

## Environment variables

| Variable | Description |
| -------- | ----------- |
| `FILES_OIDC_CLIENT_ID` | Authentik OIDC client id — vault → Komodo Variable |
| `FILES_OIDC_CLIENT_SECRET` | Authentik OIDC client secret — vault → Komodo Variable |

Both are read by the app as `FILEBROWSER_OIDC_CLIENT_ID` / `FILEBROWSER_OIDC_CLIENT_SECRET`, which
is how the secret stays out of the committed `config.yaml`. Managed with
[`scripts/secrets.sh`](../../scripts/secrets.sh) → `secrets/portainer-env/files.env`; `push files` writes the Komodo Variables and deploys.

## Dependencies

- **Authentik** — and harder than for most services: OIDC discovery runs at **startup**, and a
  failure is `logger.Fatalf`. See Common failures.
- **Caddy** — defines `proxy_files` and terminates TLS.
- **micro-vps-ingress** — the public name must be in the VPS SNI allowlist.
- Komodo's clone at `/mnt/apps/komodo/repos/nas`, pulled by every NAS deploy, for `config.yaml`.

## Notes

- Runs as UID/GID **568** (TrueNAS apps user) to match `/mnt/data/smb_share`. The image's own user
  is 1000, so every writable path is a bind mount owned by 568 — the image's `WORKDIR` is not.
- **Who may log in is the Authentik application binding**, not a claim in `config.yaml` — same
  model as [mealie](mealie.md). Since 2026-09-16 the `files` application is bound to the Authentik
  group **`nas-users`**, so only its members can log in — see
  [authentik.md → Application access](authentik.md#application-access-the-login-allowlist).
  Anonymous share and upload links are unaffected: they need no login at all.
- **Admin is the existing `authentik Admins` group**, not a files-specific one, so there is one
  admin list for the estate. The match is an exact string against the `groups` claim, space
  included. Quantum re-evaluates it on **every** login while `adminGroup` is non-empty
  (`backend/http/oidc.go`), so adding or removing someone from the group takes effect at their
  next login — no DB surgery. Leaving `adminGroup` empty instead would fall back to
  `userDefaults.permissions.admin` **at user-creation time only**, which is both a one-shot and
  would make every household member an admin.
- Every user who gets in has `modify`/`create`/`delete`/`share` on the whole share by default
  (`userDefaults.account.permissions`). Narrow a specific user in Settings → Users after their
  first login; the defaults only apply at creation.
- `server.externalUrl` is what share links are built from. It has to be the public hostname, and
  it is the one line that changes at the cutover.
- **No local login at all.** Break-glass (Authentik down and you need in) is in the
  [migration runbook](../runbooks/setup-operations/filebrowser-to-quantum.md) → Rollback.
- Tag line is `<x.y.z>-stable`. `beta` is the 2.x rewrite — `renovate.json` constrains this image
  to `/-stable$/` so a beta is never offered as a major.

## First-time UI setup

1. Browse to the URL. There is no login form — the only button is Authentik.
2. Log in. The user is provisioned from `preferred_username` on first login.
3. Admin comes from the Authentik group **`authentik Admins`**, read from the `groups` claim in
   Authentik's default `profile` scope. If you were already a user before that was configured, log
   out and in once — the promotion happens on login.
4. Settings → check the source `smb_share` is mounted and the index has finished building
   (the search box reports it).
5. Test a share: right-click a file → Share → set expiry/password → open the link in a private
   window. Then a **upload share** on a folder and drop a file through it.

## Operations

> Restart/redeploy go through **Komodo** (Stack `files`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `files` → **Deploy** (or **Restart**).
- Or push to `stacks/files/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).
- A change to **`config.yaml` alone** arrives with the deploy its push triggers, but still needs a
  container restart: the config is read at startup, and the deploy leaves an unchanged container
  running. Komodo → Stacks → `files` → **Restart**.

### Upgrade

- Pinned `tag@sha256:` in the compose file. Renovate opens the PR for the next `-stable`;
  [renovate-pr-review](../../.github/workflows/renovate-pr-review.yml) reviews it and the sweep
  merges it when cleared.

### Restore from backup

1. Stop the `files` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/files` (SQLite DB: users, shares, index, settings) from a ZFS snapshot of `apps`
   or from Hetzner. See the [backup runbook](../runbooks/backup-restore/backup.md).
3. Start the stack. The **served files** under `/mnt/data/smb_share` are restored by the
   `data/smb_share` snapshot/sync, not by this stack.

### Common failures

- **Container crash-loops right after start, log says `Error validating OIDC auth`** → OIDC
  discovery against `https://auth.example.com/application/o/files/` failed and Quantum treats
  that as fatal. Either Authentik is down, or the `files` application/provider is missing (check
  the blueprint applied: `curl -s https://auth.example.com/application/o/files/.well-known/openid-configuration`
  must return JSON). **This makes Authentik a hard start-order dependency** — after a full power
  loss, `files` cannot come up until Authentik is serving.
- **Login redirects back to a `redirect_uri` error** → the callback in the Authentik provider must
  be exactly `https://<host>/api/auth/oidc/callback`, matching mode strict.
- **Logged in but everything is read-only / no share button** → the user was created before
  `userDefaults` said otherwise. Fix that user in Settings → Users, not in `config.yaml`.
- **No admin UI despite being in `authentik Admins`** → the group name must match the claim
  exactly, space and capital A included; and the promotion only lands on a fresh login.
- **Share link opens but the file 404s** → `server.externalUrl` does not match the hostname the
  link was opened on.
- **Permission denied browsing files** → container must run as UID/GID 568 to match
  `/mnt/data/smb_share` ownership.
- **`cacheDir failed to …` at startup** → `/mnt/apps/files` is not writable by 568.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-09
