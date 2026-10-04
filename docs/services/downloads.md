# Service: Downloads (VPN-bound clients)

## Overview

Every download client, sharing a single ProtonVPN WireGuard tunnel via **gluetun**. Split out of
the old 15-service `mediaserver` stack.

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
- **Deploy:** Komodo Stack `downloads` on Server `nas` ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its
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

### Port forwarding sync

gluetun's up command pushes Proton's port once per connect and gives up after two minutes. On
2026-09-27 gluetun reconnected while qBittorrent was down, the push failed, and qBittorrent kept
listening on the old port (`47874`, Proton now forwarding `51623`) for five days. Nothing broke
visibly: outbound connections still worked, so the *Incoming port* panel stayed green, peers stayed
near 190, and Kiwix upload fell from about 60 GB/day to under 10.

[`scripts/qbit-port-sync.sh`](../../scripts/qbit-port-sync.sh) is the backstop. A host cron job runs it
every 2 minutes as root. It reads the forwarded port from gluetun's control API
(`/v1/portforward`) and qBittorrent's `listen_port`, sets the latter when they differ (logged to
syslog as `qbit-port-sync`), and writes `/mnt/apps/observability/textfile/qbit-port.prom` for
`node-exporter`:

| Series | Meaning |
| ------ | ------- |
| `qbittorrent_forwarded_port` | the port gluetun holds; `0` = Proton gave none, or gluetun is down |
| `qbittorrent_listen_port` | qBittorrent's `listen_port`; `0` = its Web API did not answer |
| `qbittorrent_listen_port_synced` | `1` when both are non-zero and equal, after any repair |

`QbittorrentPortMismatch` fires when `synced` stays `0` for 10 minutes (the repair cannot work: no
forwarded port, or qBittorrent down), and `QbittorrentPortSyncStale` when the file is missing or older
than 10 minutes (cron stopped). The *Incoming port* panel multiplies in `synced`, so a stale port now
shows FIREWALLED.

Cron job (once, after the merge has reached the host clone):

```sh
sudo midclt call cronjob.create '{"description":"qbittorrent port sync",
  "command":"/bin/sh /mnt/apps/scripts/nas/scripts/qbit-port-sync.sh",
  "user":"root","schedule":{"minute":"*/2","hour":"*","dom":"*","month":"*","dow":"*"},
  "enabled":true,"stdout":false,"stderr":false}'
sudo sh /mnt/apps/scripts/nas/scripts/qbit-port-sync.sh
grep -v '^#' /mnt/apps/observability/textfile/qbit-port.prom    # all three non-zero, synced 1
```

## Operations

### Restart / redeploy

Komodo → Stacks → `downloads` → **Restart** or **Deploy**, or push to `stacks/downloads/` (the runner deploys it
through Komodo). On (re)deploy the
three clients wait for gluetun to report healthy, so expect a delay while the tunnel comes up.

### Upgrade

Every image is pinned `tag@sha256:digest`; Renovate proposes bumps. Because this is now its own
stack, a gluetun bump gets **its own risk verdict and its own rollback** instead of sharing one
with fourteen unrelated services.

qbittorrent and sabnzbd are linuxserver images, updated only through the regex-versioning rules in
`renovate.json` (see [arr.md → Upgrade](arr.md#upgrade)); the `_v<libtorrent>` part of the
qbittorrent tag is ignored for ordering.

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
  an old port → its Web API was unreachable for the whole retry window.
  [`qbit-port-sync.sh`](#port-forwarding-sync) corrects it within 2 minutes; by hand:
  `sudo docker exec gluetun sh -c 'wget -qO- --post-data "json={\"listen_port\":$(cat /tmp/gluetun/forwarded_port)}" http://127.0.0.1:8082/api/v2/app/setPreferences'`.
- **`qbittorrent` target down, or the exporter logs `Authentication Error` / `banned your IP`** → the
  localhost bypass is off. Its failed logins count toward qBittorrent's ban of `127.0.0.1`, which also
  blocks gluetun's port handoff: switch the bypass back on and restart `qbittorrent`, which clears the ban.
- **`sabnzbd` target down, exporter logs `API Key Incorrect`** → the SABnzbd API key was
  regenerated. `scripts/secrets.sh edit downloads`, `push downloads`.
- **`arr` apps cannot reach the download client** → they address it as `gluetun:8082`, which needs
  `media_net`. `docker network inspect media_net` should list both gluetun and the arr containers.
