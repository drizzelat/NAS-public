# Service: Jellyfin (+ Seerr)

## Overview

Media playback and its request front-end — the **public-facing** half of the old `mediaserver`
stack, split out on 2026-08-21
([STR-1](../architecture-review-2026-08-20.md#str-1--split-the-15-service-mediaserver-stack)).
It is the highest-value service in the group and now gets its own risk verdict and its own
rollback instead of sharing one with fourteen others.

### Containers

| Container | Role |
| --- | --- |
| jellyfin | Media player / streaming server |
| seerr | Media request UI |
| jellyfin-exporter | Prometheus metrics (sessions, transcodes, library counts, tasks, storage) on `:9594`, for the *Media stack* dashboard |

## Stack

- **Stack folder:** `stacks/jellyfin/`
- **Compose file:** `stacks/jellyfin/docker-compose.yml`
- **Deploy:** Komodo Stack `jellyfin` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Service | URL | Port |
| --- | --- | --- |
| Jellyfin | `https://jellyfin.example.com` | 8096 |
| Seerr | `https://seerr.example.com` | 5055 |

**Jellyfin is public** behind Authentik SSO. **Seerr stays LAN-only** (not in the VPS SNI
allowlist; Caddy's `lan_only` snippet aborts any other client). The exporter has no route:
`victoriametrics` joins `proxy_jellyfin` and scrapes `jellyfin-exporter:9594` (job `jellyfin`).

## Volumes / data

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/config` (jellyfin) | `/mnt/apps/mediaserver/config/jellyfin` | Jellyfin config |
| `/app/config` (seerr) | `/mnt/apps/mediaserver/config/seerr` | Seerr config |
| `/data/media` | `/mnt/data/mediaserver/data/media` | Media library |

> Host paths deliberately stayed under `/mnt/apps/mediaserver/` — the split regrouped *stacks*,
> not data. The Jellyfin cloud-sync task still excludes its regenerable `cache/` directory.

## Environment variables

Set from the vault (`secrets.enc/portainer-env/jellyfin.env.age`) as the Komodo Variables `JELLYFIN__<KEY>` (`scripts/secrets.sh push jellyfin` writes them and deploys) —
see the [secret-sync runbook](../runbooks/setup-operations/secret-sync.md).

| Variable | Description |
| --- | --- |
| `JELLYFIN_EXPORTER_TOKEN` | A Jellyfin API key named `jellyfin-exporter` (Dashboard → API Keys). Server API keys act as admin, so it gets its own revocable key rather than reusing Seerr's |

## Dependencies

- **`media_net`** (external) — Seerr addresses `sonarr:8989` and `radarr:7878`, which live in the
  [`arr`](arr.md) stack. Those hostnames are stored in Seerr's own `settings.json`, not in
  compose, so this dependency is invisible to the repo.
- Intra-stack: Seerr → `jellyfin` on the plain `default` network.
- `proxy_jellyfin` (external) — defined by the `caddy` stack. `jellyfin-exporter` joins it so
  [observability](observability.md) can scrape it.
- `/dev/dri` passthrough (Intel iGPU) for hardware transcoding, group IDs 44 (video) and 107
  (render).

## Notes

- **Jellyfin is public behind Authentik SSO** (web UI only, via `9p4/jellyfin-plugin-sso`). The
  login page shows only *Sign in with authentik* plus Quick Connect; the native form is hidden
  (cosmetic only). The real block is Caddy's **public `:8443` site block**, which returns `403` for
  the password endpoints (`/Users/AuthenticateByName`, `/Users/{id}/Authenticate`, `/Users/Public`)
  — LAN/tailnet `:443` and Seerr's internal path keep native login.
- **Who may log in through SSO is the Authentik `nas-users` binding** (since 2026-09-16) — see
  [authentik.md → Application access](authentik.md#application-access-the-login-allowlist). It gates
  the SSO path only; Seerr and LAN native login run on Jellyfin's own accounts.
- **Seerr signs in with a Jellyfin username + local password**, so every household Jellyfin
  account must keep a strong local password even though SSO provisions it.
- Off-LAN native apps log in via **Quick Connect**, approved from an SSO'd web session.
- Jellyfin is **grey-cloud (DNS-only)** at Cloudflare.
- Full design: [jellyfin-authentik-sso runbook](../runbooks/setup-operations/jellyfin-authentik-sso.md).
- **The exporter is `rebelcore/jellyfin-exporter`** with the `transcoding`, `tasks` and `storage`
  collectors on top of the defaults. `activity` stays off: it needs the Playback Reporting plugin.
  The scrape job drops the `ip_address`, `client_version` and `last_access` labels, so client IPs
  never reach the 1-year metrics store (the same rule the Caddy counters follow) and a login does
  not mint a new series. Now-playing series are labelled by title, so every played item adds a few
  short-lived series; that is the intended cost of the *Now playing* table.

## Operations

### Restart / redeploy

Komodo → Stacks → `jellyfin` → **Restart** or **Deploy**, or push to `stacks/jellyfin/` (the runner deploys it
through Komodo).

### Upgrade

Pinned `tag@sha256:digest`; Renovate proposes bumps. **Read Jellyfin's release notes** — this is
the service whose major bumps most deserve a deliberate look, which is exactly what it could not
get while bundled with fourteen others.

### Restore from backup

1. Stop the stack.
2. Restore `apps/mediaserver/config/jellyfin` and `.../seerr` from a ZFS snapshot or Hetzner.
3. `data/mediaserver` (the media library) is **intentionally not backed up** — large and
   re-acquirable.
4. Start the stack.

### Common failures

- **No hardware transcode** → `/dev/dri` passthrough and iGPU group IDs 44 / 107.
  The *Active transcodes* table on the Media stack dashboard shows an empty *HW accel* column for
  software encodes.
- **`jellyfin` target down, exporter logs `401`** → the `jellyfin-exporter` API key was revoked.
  Create a new one, `scripts/secrets.sh edit jellyfin`, `push jellyfin`.
- **Seerr shows no Sonarr/Radarr** → they live in the `arr` stack; check `media_net`.
- **Public login fails but LAN works** → intended: the public edge `403`s the password endpoints.
  Use SSO or Quick Connect.
- **Authentik shows "Redirect URI Error" on the SSO button** → Jellyfin sent `http://` instead of
  `https://` and the provider matches `strict`. The plugin builds the redirect from
  `Request.Scheme`, which is only `https` when Jellyfin trusts the fronting proxy. Check
  Dashboard → Networking → **Known Proxies** (`network.xml` → `KnownProxies`) against the live
  `proxy_jellyfin` subnet — it must be Caddy's, not a stale one. Confirm the sent value in
  `docker logs authentik-server-1 | grep redirect_uri_no_match`.
- **SSO login works but the admin dashboard is missing** → the SSO plugin owns `IsAdministrator`
  whenever **Enable Authorization by Plugin** is on, and it *rewrites* the flag on every login.
  Empty `AdminRoles` (or a null `RoleClaim`) therefore demotes you each time, silently undoing any
  manual promotion. As-built: `RoleClaim = groups`, `AdminRoles = ["authentik Admins"]`.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-14
