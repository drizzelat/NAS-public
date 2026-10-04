# Services

One file per service. File name matches the stack folder name under `stacks/`.

## On the NAS

| Service | Stack | Description |
| --- | --- | --- |
| [AdGuard Home](adguard.md) | `stacks/adguard/` | Network-wide DNS server and ad/tracker blocker; primary LAN resolver |
| [arr](arr.md) | `stacks/arr/` | *arr automation suite: prowlarr, radarr, sonarr, bazarr, unpackerr, questarr |
| [Authentik](authentik.md) | `stacks/authentik/` | Identity provider and SSO (OAuth2/OIDC); provider config in git as blueprints |
| [Books](books.md) | `stacks/books/` | Shelfmark book library |
| [Caddy](caddy.md) | `stacks/caddy/` | Edge reverse proxy + CrowdSec: TLS for every `*.example.com` name, the whole access policy in one Caddyfile; replaced NPMplus |
| [Conduit](conduit.md) | `stacks/conduit/` | Psiphon Conduit station — outbound-only WebRTC relay into the Psiphon network for censored users |
| [Downloads](downloads.md) | `stacks/downloads/` | Download clients behind the Gluetun VPN killswitch — must stay one stack |
| [Files](files.md) | `stacks/files/` | FileBrowser Quantum — web UI for NAS files with Authentik OIDC, share links and upload links |
| [Games](games.md) | `stacks/games/` | GameVault and its own Postgres |
| [GitHub Actions Runner](github-runner.md) | `stacks/github-runner/` | Self-hosted runner: stack deploys through Komodo, nightly health check, deploy-state probe |
| [Immich](immich.md) | `stacks/immich/` | Self-hosted photo and video backup and gallery with ML features |
| [Jellyfin (+ Seerr)](jellyfin.md) | `stacks/jellyfin/` | Media player (public, Authentik SSO) and its request UI (LAN-only) |
| [Komodo Core](komodo.md) | `stacks/komodo/` (deployed by itself, not CI) | The control plane: deploys every stack through a periphery on each host |
| [Uptime Kuma](kuma.md) | `stacks/kuma/` | Internal uptime monitoring; the external watchdog is [A1 Uptime Kuma](a1-vps-kuma.md) |
| [NAS periphery](nas-periphery.md) | `stacks/nas-periphery/` (applied by hand, not by Komodo) | Komodo periphery on the NAS |
| [Mealie](mealie.md) | `stacks/mealie/` | Recipe manager and meal planner (public via Authentik OIDC) |
| [Observability](observability.md) | `stacks/observability/` | Vector + VictoriaLogs + VictoriaMetrics + Grafana — traffic and service analytics; replaced GoAccess |
| [RomM](romm.md) | `stacks/romm/` | Retro game library — browser emulation (EmulatorJS) + SMB share for GameCube/Wii/Switch |
| [Runner VM periphery](runner-vm-periphery.md) | `stacks/runner-vm-periphery/` (applied over SSH, not by Komodo) | Komodo periphery inside the runner VM |
| [Snowflake](snowflake.md) | `stacks/snowflake/` | Tor Snowflake proxy — outbound-only WebRTC relay for censored Tor users |
| [Tailscale](tailscale.md) | `stacks/tailscale/` | Subnet router — remote LAN access, and the backhaul the public ingress rides |

## Off the NAS (Oracle Cloud)

| Service | Stack | Description |
| --- | --- | --- |
| [A1 periphery](a1-vps-periphery.md) | `stacks/a1-vps-periphery/` (applied over SSH, not by Komodo) | Komodo periphery on the A1 |
| [A1 node-exporter](a1-vps-node-exporter.md) | `stacks/a1-vps-node-exporter/` | Host metrics of the A1 (CPU, memory, network, disk), scraped by the NAS over the tailnet |
| [A1 Uptime Kuma](a1-vps-kuma.md) | `stacks/a1-vps-kuma/` | External watchdog: stays up when the NAS or home internet is down. On the A1, not the ingress VPS, so it does not share a failure domain with what it watches |
| [A1 NTP Pool server](a1-vps-ntp.md) | `stacks/a1-vps-ntp/` | chrony serving `pool.ntp.org` clients on public UDP 123; never touches the host clock |
| [A1 Tor bridge](a1-vps-tor-bridge.md) | `stacks/a1-vps-tor-bridge/` | Tor obfs4 bridge — unlisted, never an exit; egress capped at 1 TiB/month |
| [A1 WebTunnel bridge](a1-vps-webtunnel.md) | `stacks/a1-vps-webtunnel/` | Tor WebTunnel bridge plus the A1's Caddy (owns `:80`/`:443`), from a self-built arm64 image rebuilt on upstream fixes; egress capped at 1 TiB/month |
| [VPS node-exporter](micro-vps-node-exporter.md) | `stacks/micro-vps-node-exporter/` | Host metrics of the micro VPS, scraped by the NAS over the tailnet |
| [VPS periphery](micro-vps-periphery.md) | `stacks/micro-vps-periphery/` (applied over SSH, not by Komodo) | Komodo periphery on the micro VPS |
| [VPS ingress](micro-vps-ingress.md) | `stacks/micro-vps-ingress/` | Public front door: nginx stream with an SNI allowlist and a Cloudflare-only gate, forwarding `:443` to Caddy `:8443` over Tailscale |

> AI agents: when you add a service, add a row to this table and create the corresponding `<name>.md` file using [`_template.md`](_template.md).
