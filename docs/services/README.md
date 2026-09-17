# Services

One file per service. File name matches the stack folder name under `stacks/`.

## On the NAS

| Service | Stack | Description |
| --- | --- | --- |
| [AdGuard Home](adguard.md) | `stacks/adguard/` | Network-wide DNS server and ad/tracker blocker; primary LAN resolver |
| [arr](arr.md) | `stacks/arr/` | *arr automation suite: prowlarr, radarr, sonarr, bazarr, unpackerr, questarr |
| [Authentik](authentik.md) | `stacks/authentik/` | Identity provider and SSO (OAuth2/OIDC); provider config in git as blueprints |
| [Beszel](beszel.md) | `stacks/beszel/` | Lightweight server monitoring dashboard (hub + NAS agent) |
| [Books](books.md) | `stacks/books/` | Shelfmark book library |
| [Caddy](caddy.md) | `stacks/caddy/` | Edge reverse proxy + CrowdSec: TLS for every `*.example.com` name, the whole access policy in one Caddyfile; replaced NPMplus |
| [Conduit](conduit.md) | `stacks/conduit/` | Psiphon Conduit station — outbound-only WebRTC relay into the Psiphon network for censored users |
| [Downloads](downloads.md) | `stacks/downloads/` | Download clients behind the Gluetun VPN killswitch — must stay one stack |
| [Files](files.md) | `stacks/files/` | FileBrowser Quantum — web UI for NAS files with Authentik OIDC, share links and upload links |
| [Games](games.md) | `stacks/games/` | GameVault and its own Postgres |
| [GitHub Actions Runner](github-runner.md) | `stacks/github-runner/` | Self-hosted runner: stack deploys through Komodo, nightly health check, deploy-state probe |
| [Homarr](homarr.md) | `stacks/homarr/` | Dashboard / start page for all apps and services |
| [Immich](immich.md) | `stacks/immich/` | Self-hosted photo and video backup and gallery with ML features |
| [Jellyfin (+ Seerr)](jellyfin.md) | `stacks/jellyfin/` | Media player (public, Authentik SSO) and its request UI (LAN-only) |
| [Uptime Kuma](kuma.md) | `stacks/kuma/` | Internal uptime monitoring; the external watchdog is [A1 Uptime Kuma](a1-vps-kuma.md) |
| [Mealie](mealie.md) | `stacks/mealie/` | Recipe manager and meal planner (public via Authentik OIDC) |
| [Observability](observability.md) | `stacks/observability/` | Vector + VictoriaLogs + VictoriaMetrics + Grafana — traffic and service analytics; replaced GoAccess |
| [Paperless-ngx](paperless.md) | `stacks/paperless/` | Document management — searchable archive of scanned documents |
| [RomM](romm.md) | `stacks/romm/` | Retro game library — browser emulation (EmulatorJS) + SMB share for GameCube/Wii/Switch |
| [Runner VM periphery](runner-vm-periphery.md) | `stacks/runner-vm-periphery/` (applied over SSH, not by Komodo) | Komodo periphery inside the runner VM |
| [Snowflake](snowflake.md) | `stacks/snowflake/` | Tor Snowflake proxy — outbound-only WebRTC relay for censored Tor users |
| [Tailscale](tailscale.md) | `stacks/tailscale/` | Subnet router — remote LAN access, and the backhaul the public ingress rides |

## Off the NAS (Oracle Cloud)

| Service | Stack | Description |
| --- | --- | --- |
| [A1 Beszel agent](a1-vps-beszel-agent.md) | `stacks/a1-vps-beszel-agent/` | Beszel agent reporting the A1 to the hub on the NAS (WebSocket, outbound) |
| [A1 Uptime Kuma](a1-vps-kuma.md) | `stacks/a1-vps-kuma/` | External watchdog: stays up when the NAS or home internet is down. On the A1, not the ingress VPS, so it does not share a failure domain with what it watches |
| [A1 Matrix](a1-vps-matrix.md) | `stacks/a1-vps-matrix/` | Matrix homeserver (Synapse + Postgres + Caddy + Element Web + mautrix-whatsapp); its Caddy also fronts the WebTunnel bridge |
| [A1 NTP Pool server](a1-vps-ntp.md) | `stacks/a1-vps-ntp/` | chrony serving `pool.ntp.org` clients on public UDP 123; never touches the host clock |
| [A1 Tor bridge](a1-vps-tor-bridge.md) | `stacks/a1-vps-tor-bridge/` | Tor obfs4 bridge — unlisted, never an exit; egress capped at 1 TiB/month |
| [A1 WebTunnel bridge](a1-vps-webtunnel.md) | `stacks/a1-vps-webtunnel/` | Tor WebTunnel bridge behind the Matrix Caddy, from a self-built arm64 image rebuilt on upstream fixes; egress capped at 1 TiB/month |
| [VPS Beszel agent](micro-vps-beszel-agent.md) | `stacks/micro-vps-beszel-agent/` | Beszel agent reporting the micro VPS to the hub on the NAS (WebSocket, outbound) |
| [VPS ingress](micro-vps-ingress.md) | `stacks/micro-vps-ingress/` | Public front door: nginx stream with an SNI allowlist and a Cloudflare-only gate, forwarding `:443` to Caddy `:8443` over Tailscale |

## Archived

Stacks that no longer run. Kept for bootstrap history and rollback.

| Service | Archived | Replaced by |
| ------- | -------- | ----------- |
| [nginx Proxy Manager](../archive/npm.md) | 2026-09-07 | [caddy](caddy.md) |
| [File Browser](../archive/filebrowser.md) | 2026-09-09 | [files](files.md) |
| [QDirStat](../archive/qdirstat.md) | 2026-09-15 | nothing, no longer needed |
| [Portainer](../archive/portainer.md) | 2026-09-17 | [komodo](komodo.md) |
| [A1 Portainer agent](../archive/a1-vps-agent.md) | 2026-09-17 | [a1-vps-periphery](a1-vps-periphery.md) |
| [micro VPS Portainer agent](../archive/micro-vps-agent.md) | 2026-09-17 | [micro-vps-periphery](micro-vps-periphery.md) |

> AI agents: when you add a service, add a row to this table and create the corresponding `<name>.md` file using [`_template.md`](_template.md).
