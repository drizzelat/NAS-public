# Service: Downloads (VPN-bound clients)

## Overview

Every download client, sharing a single ProtonVPN WireGuard tunnel via **gluetun**. Split out of
the old 15-service `mediaserver` stack on 2026-08-21
([STR-1](../architecture-review-2026-08-20.md#str-1--split-the-15-service-mediaserver-stack)).

**These must stay one stack.** `qbittorrent`, `sabnzbd` and `flaresolverr` all run
`network_mode: service:gluetun` — they share gluetun's network namespace and have no network at
all without it. That constraint is what makes this split line natural rather than arbitrary.

### Containers

| Container | Role |
| --- | --- |
| gluetun | VPN kill-switch (ProtonVPN WireGuard) |
| qbittorrent | Torrent client (network via gluetun) |
| sabnzbd | Usenet client (network via gluetun) |
| flaresolverr | Cloudflare bypass for Prowlarr (network via gluetun) |
| qbittorrent-exporter | Prometheus metrics for qBittorrent on `:9022`, for the Kiwix section of the *Community services* dashboard and the *Media stack* dashboard (network via gluetun) |
| exportarr-sabnzbd | Prometheus metrics for SABnzbd on `:9023`, for the *Media stack* dashboard (network via gluetun) |

## Stack

- **Stack folder:** `stacks/downloads/`
- **Compose file:** `stacks/downloads/docker-compose.yml`
- **Deploy:** Komodo Stack `downloads` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Service | URL | Port |
| --- | --- | --- |
| qBittorrent | `https://qbittorrent.example.com` | 8082 |
| SABnzbd | `https://sabnzbd.example.com` | 8080 |

LAN-only — not in the VPS SNI allowlist, and Caddy's `lan_only` snippet aborts any other client.
All three share gluetun's network namespace, so every port is on `gluetun` (qBittorrent moved to
`8082` because SABnzbd holds `8080`). FlareSolverr (8191) has no route; only Prowlarr talks to it.
The qBittorrent exporter (`9022`) and the SABnzbd exporter (`9023`) have none either:
`victoriametrics` joins `proxy_downloads` and scrapes `gluetun:9022` (job `qbittorrent`) and
`gluetun:9023` (job `sabnzbd`). Any new service in gluetun's namespace needs a port not already on
this list.

## Volumes / data

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/gluetun` | `/mnt/apps/mediaserver/config/gluetun` | Gluetun VPN state |
| `/config` (qbittorrent) | `/mnt/apps/mediaserver/config/qbittorrent` | qBittorrent config |
| `/config` (sabnzbd) | `/mnt/apps/mediaserver/config/sabnzbd` | SABnzbd config |
| `/data` (shared) | `/mnt/data/mediaserver/data` | Downloads + media files |
| `/roms` (qbittorrent) | `/mnt/data/romm/roms` | RomM library (heavy grabs) |

> **Host paths deliberately stayed under `/mnt/apps/mediaserver/`.** The split regrouped
> *stacks*, not data — moving datasets would have turned a mechanical change into a migration
> with a restore path to get wrong.

## Environment variables

| Variable | Description |
| --- | --- |
| `WG_KEY` | ProtonVPN WireGuard private key, from a config generated with **NAT-PMP (port forwarding)** on |
| `SABNZBD_KEY` | SABnzbd API key for `exportarr-sabnzbd` — Config → General → Security. Reaches SABnzbd on `127.0.0.1:8080`, which its host whitelist always admits |

## Dependencies

- **`media_net`** (external) — gluetun joins it so the `arr` stack can still reach the clients by
  the hostname `gluetun`. See [arr.md](arr.md).
- `proxy_downloads` (external) — defined by the `caddy` stack.

## Notes

- **VPN kill-switch**: the three clients only have internet through gluetun. If the VPN drops,
  their traffic stops. Gluetun's own healthcheck marks it unhealthy, and `depends_on:
  service_healthy` keeps the clients down until the tunnel is up.
- **Inbound port forwarding**: `VPN_PORT_FORWARDING=on` (ProtonVPN NAT-PMP). Proton assigns a
  **dynamic** port and `VPN_PORT_FORWARDING_UP_COMMAND` pushes it into qBittorrent's `listen_port`
  over the local Web API, retrying for two minutes because gluetun usually has the port before
  qBittorrent's Web API is listening. Inbound P2P therefore arrives over the tunnel, not the NAS WAN — the
  stack publishes **no host torrent ports**. Three prerequisites, all required:
  - qBittorrent → Options → Web UI → *"Bypass authentication for clients on localhost"* on (it is),
    else gluetun's call is rejected 403. The exporter logs in the same way, which is why it stores no
    password.
  - `PORT_FORWARD_ONLY=on`, so gluetun only picks Proton's P2P servers. The others refuse NAT-PMP.
  - `WG_KEY` from a WireGuard config generated with **NAT-PMP (Port Forwarding)** switched on in the
    Proton dashboard.

  **Working since 2026-09-14**, after the key was regenerated with NAT-PMP. Before that, every
  reconnect since at least 2026-09-08 logged `port forwarding ... connection refused - make sure you
  have +pmp`, and qBittorrent sat on its default `6881`, so no peer could connect in. Key rotation:
  [kiwix-seeding](../runbooks/setup-operations/kiwix-seeding.md#1-make-port-forwarding-work).
- **Kiwix seeding**: the `kiwix` category (`/data/torrents/kiwix`) belongs to
  [`scripts/kiwix-seed.sh`](../../scripts/kiwix-seed.sh), which adds the newest offline Wikipedia and
  Gutenberg ZIMs and removes what they supersede. Anything else put in that category is removed on
  its next run; hand-added community torrents go in a category of their own. The \*arr apps only
  watch their own categories. Details: [kiwix-seeding](../runbooks/setup-operations/kiwix-seeding.md).
- PUID/PGID **950** is `truenas_admin`'s uid/gid on this host; it must own `/mnt/data/mediaserver/data`.

## Operations

### Restart / redeploy

Komodo → Stacks → `downloads` → **Restart** or **Deploy**, or push to `stacks/downloads/` (the runner deploys it
through Komodo). On (re)deploy the
three clients wait for gluetun to report healthy, so expect a delay while the tunnel comes up.

### Upgrade

Every image is pinned `tag@sha256:digest`; Renovate proposes bumps. Because this is now its own
stack, a gluetun bump gets **its own risk verdict and its own rollback** instead of sharing one
with fourteen unrelated services.

### Restore from backup

1. Stop the stack.
2. Restore `apps/mediaserver/config/{gluetun,qbittorrent,sabnzbd}` from a ZFS snapshot or Hetzner.
3. `data/mediaserver` (the downloads themselves) is **intentionally not backed up**.
4. Start the stack.

### Common failures

- **Clients have no internet or won't start** → gluetun is unhealthy. Check its logs, `WG_KEY`,
  and ProtonVPN status.
- **Torrents connectable but no incoming peers** → one of the three port-forwarding prerequisites above.
- **gluetun logs `port forwarding ... connection refused - make sure you have +pmp`** → the WireGuard
  key was generated without NAT-PMP, or gluetun picked a non-P2P server. Regenerate the key with
  NAT-PMP on and keep `PORT_FORWARD_ONLY=on`. Confirm with
  `sudo docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/portforward` (a non-zero `port`).
- **gluetun logs `[port forwarding] running up command: exit status 1`** (or `4`), qBittorrent still on
  an old port → its Web API was unreachable for the whole retry window. Hand the port over yourself:
  `sudo docker exec gluetun sh -c 'wget -qO- --post-data "json={\"listen_port\":$(cat /tmp/gluetun/forwarded_port)}" http://127.0.0.1:8082/api/v2/app/setPreferences'`.
- **`qbittorrent` target down, or the exporter logs `Authentication Error` / `banned your IP`** → the
  localhost bypass is off. Its failed logins count toward qBittorrent's ban of `127.0.0.1`, which also
  blocks gluetun's port handoff: switch the bypass back on and restart `qbittorrent`, which clears the ban.
- **`sabnzbd` target down, exporter logs `API Key Incorrect`** → the SABnzbd API key was
  regenerated. `scripts/secrets.sh edit downloads`, `push downloads`.
- **`arr` apps cannot reach the download client** → they address it as `gluetun:8082`, which needs
  `media_net`. `docker network inspect media_net` should list both gluetun and the arr containers.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-14
