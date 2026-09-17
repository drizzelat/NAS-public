# Service: arr (automation suite)

## Overview

The *arr automation suite: indexer management, movie/TV automation, subtitles, extraction and
queue management. Split out of the old 15-service `mediaserver` stack on 2026-08-21
([STR-1](../architecture-review-2026-08-20.md#str-1--split-the-15-service-mediaserver-stack)).

### Containers

| Container | Role |
| --- | --- |
| prowlarr | Indexer manager / proxy for the other *arr apps |
| radarr | Movie automation |
| sonarr | TV automation |
| bazarr | Subtitle automation |
| unpackerr | Auto-extracts completed downloads |
| questarr | Queue manager / dashboard |
| exportarr-sonarr, exportarr-radarr, exportarr-prowlarr, exportarr-bazarr | One Prometheus exporter per app on `:9707`, for the *Media stack* dashboard |

## Stack

- **Stack folder:** `stacks/arr/`
- **Compose file:** `stacks/arr/docker-compose.yml`
- **Deploy:** Komodo Stack `arr` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Service | URL | Port |
| --- | --- | --- |
| Prowlarr | `https://prowlarr.example.com` | 9696 |
| Radarr | `https://radarr.example.com` | 7878 |
| Sonarr | `https://sonarr.example.com` | 8989 |
| Bazarr | `https://bazarr.example.com` | 6767 |
| Questarr | `https://questarr.example.com` | 5000 |

All LAN-only — not in the VPS SNI allowlist, and Caddy's `lan_only` snippet aborts any other
client. Unpackerr has no UI. The exporters have no route either: `victoriametrics` joins `proxy_arr`
and scrapes `exportarr-<app>:9707` (jobs `sonarr`, `radarr`, `prowlarr`, `bazarr`).

## Volumes / data

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/config` (prowlarr) | `/mnt/apps/mediaserver/config/prowlarr` | Prowlarr config |
| `/config` (radarr) | `/mnt/apps/mediaserver/config/radarr` | Radarr config |
| `/config` (sonarr) | `/mnt/apps/mediaserver/config/sonarr` | Sonarr config |
| `/config` (bazarr) | `/mnt/apps/mediaserver/config/bazarr` | Bazarr config |
| `/config` (unpackerr) | `/mnt/apps/mediaserver/config/unpackerr` | Unpackerr config |
| `/app/data` (questarr) | `/mnt/apps/mediaserver/config/questarr` | Questarr SQLite DB |
| `/data` (radarr, sonarr, unpackerr, questarr) | `/mnt/data/mediaserver/data` | Downloads + media files |
| `/data/media` (bazarr) | `/mnt/data/mediaserver/data/media` | Media library only — subtitles need no downloads |

> Host paths deliberately stayed under `/mnt/apps/mediaserver/` — the split regrouped *stacks*,
> not data.

## Environment variables

| Variable | Description |
| --- | --- |
| `SONARR_KEY` | Sonarr API key (Unpackerr and `exportarr-sonarr`) |
| `RADARR_KEY` | Radarr API key (Unpackerr and `exportarr-radarr`) |
| `PROWLARR_KEY` | Prowlarr API key (`exportarr-prowlarr`) — Settings → General → Security |
| `BAZARR_KEY` | Bazarr API key (`exportarr-bazarr`) — Settings → General → Security |

> `LIDARR_KEY` existed in the old `mediaserver` env but no `lidarr` service has ever been in the
> stack. It was dropped rather than carried into a new one.

## Dependencies

- **`media_net`** (external) — **load-bearing.** These apps address the download clients as the
  hostname `gluetun`, which now lives in the [`downloads`](downloads.md) stack:
  - `sonarr` / `radarr` → qBittorrent at `gluetun:8082`
  - `prowlarr` → FlareSolverr at `http://gluetun:8191/`

  Those hostnames are stored in each app's **own config database**, not in compose, so nothing in
  this repo would have caught them breaking. Without `media_net` the split would silently stop
  every download and subtitle fetch.
- Intra-stack (plain `default` network): `prowlarr` → `radarr:7878` / `sonarr:8989`,
  `bazarr` → `sonarr` / `radarr`, `unpackerr` → `http://sonarr:8989` and `http://radarr:7878`.
- `proxy_arr` (external) — defined by the `caddy` stack. The exporters join it so
  [observability](observability.md) can scrape them.

## Notes

- **Hardlinks:** radarr, sonarr, unpackerr and the download clients share
  `/mnt/data/mediaserver/data` so completed downloads are hardlinked, not copied. PUID/PGID **950**
  (`truenas_admin`) must own that path.
- Seerr (in the [`jellyfin`](jellyfin.md) stack) also reaches `sonarr` and `radarr` over
  `media_net`.
- **Exporters are exportarr v2**, one container per app because exportarr serves a single app per
  process. v3 (per-collector error gauges, histogram scores) is documented upstream but unreleased.
  In v2 an unreachable app fails the whole scrape, so the dashboard's *Status* tile reads DOWN
  rather than showing stale numbers.
- **Bazarr's `bazarr_subtitles_score_total` is dropped at scrape time.** It carries one series per
  distinct score percentage, which only grows over a year of retention; see `scrape.yml`.
- **Prowlarr's per-indexer counters start at zero when `exportarr-prowlarr` starts.** Backfill is
  off, so a restart resets them; `increase()` in the dashboard absorbs that.

## Operations

### Restart / redeploy

Komodo → Stacks → `arr` → **Restart** or **Deploy**, or push to `stacks/arr/` (the runner deploys it
through Komodo).

### Upgrade

Images are pinned `tag@sha256:digest`; Renovate proposes bumps. Renovate groups by
`{{packageFileDir}}`, so these six now bundle into **their own** PR with their own risk verdict —
a bazarr patch no longer shares a grade, or a rollback, with a Jellyfin major.

### Restore from backup

1. Stop the stack.
2. Restore the needed `apps/mediaserver/config/<app>` dataset(s) from a ZFS snapshot or Hetzner.
3. `data/mediaserver` (the library itself) is **intentionally not backed up** — only the config
   that rebuilds it.
4. Start the stack.

### Common failures

- **"cross-device link" on import** → the shared `/mnt/data/mediaserver/data` mount or PUID/PGID
  950 ownership.
- **Downloads never start; client "unavailable"** → the app addresses `gluetun`, so check
  `media_net` membership and that gluetun is healthy in the `downloads` stack.
- **Indexers fail with Cloudflare challenges** → FlareSolverr at `gluetun:8191`, same path.
- **Can't reach a UI off-LAN** → by design. Use Tailscale, or the FritzBox WireGuard fallback.
- **An app shows DOWN on the Media stack dashboard but its UI works** → the exporter's API key is
  stale (regenerated in the app). `docker logs exportarr-<app>` shows `401`; update the key with
  `scripts/secrets.sh edit arr` and `push arr`.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-14
