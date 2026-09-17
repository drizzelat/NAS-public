# Network

## NAS host

| Field       | Value                      |
| ----------- | -------------------------- |
| Hostname    | nas.example.com          |
| LAN IP      | 192.168.178.111, static    |
| Interface   | `br0`, a bridge over `enp2s0` (Realtek `r8169`) |
| MAC address | `br0` `d6:09:5b:49:52:c3`; `enp2s0` `9c:6b:00:84:26:37` |

> **The LAN address sits on the bridge `br0`**, not on `enp2s0`, since 2026-09-17. The
> [runner VM](#runner-vm)'s NIC attaches to `br0`, which is how it reaches its own host. Only `enp2s0` is
> enslaved, STP is off, and the address is static. TrueNAS gave the bridge a random MAC, so the
> FritzBox sees `d6:09:5b:49:52:c3` for `.111`. The bridge carries no global IPv6 address, only
> link-local, and nothing on the NAS relies on one. A first attempt on DHCP with STP on cost about
> 108 s of outage and rolled itself back (komodo-migration.md F33).

> **EEE is disabled on `enp2s0`** (TrueNAS Post-Init script `ethtool --set-eee enp2s0 eee
> off`). Energy Efficient Ethernet on this Realtek NIC causes silent ~10% packet loss on an
> idle link — do not re-enable it. See
> [runbooks/incident-response/nas-nic-packet-loss.md](runbooks/incident-response/nas-nic-packet-loss.md).

## SSH access

| Field       | Value                                    |
| ----------- | ---------------------------------------- |
| User        | `truenas_admin`                          |
| Host        | `192.168.178.111` (nas.example.com)    |
| Private key | `secrets/ssh/truenas_ed25519`            |
| Public key  | `secrets/ssh/truenas_ed25519.pub`        |

> **Where the key lives.** The private key is stored **encrypted in the age vault**
> (`secrets.enc/ssh/truenas_ed25519.age`); `scripts/secrets.sh unlock` restores it to the
> gitignored `secrets/ssh/`. Every SSH command in these docs uses that path, relative to the repo
> root — it works unchanged from Linux and Windows OpenSSH, and needs no copy into `~/.ssh/`. See
> the [secret-sync runbook](runbooks/setup-operations/secret-sync.md).

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
```

Public key must be added to TrueNAS: Credentials → Users → truenas_admin → Edit → SSH Public Keys.

### `nashealth` — the health check's own user

A second SSH user exists purely for the [nightly health
check](runbooks/setup-operations/nas-health-check.md): `nashealth`, key
`secrets/ssh/nas-health_ed25519`, home `/mnt/apps/nas-health`. Its
`authorized_keys` pins a forced command, so the key yields a fixed list of
read-only report verbs and no shell. It is not an administrative login and is no
use for the commands on this page — CI holds this one so it does not have to hold
`truenas_admin`.

## Runner VM

A TrueNAS VM on the NAS that hosts the self-hosted GitHub Actions runner. Details and rebuild:
[runbooks/setup-operations/runner-vm.md](runbooks/setup-operations/runner-vm.md).

| Field       | Value                                                     |
| ----------- | --------------------------------------------------------- |
| LAN IP      | `192.168.178.34`, DHCP with a FritzBox reservation         |
| NIC         | virtio on the NAS's `br0`, MAC `00:a0:98:30:ac:6c`          |
| SSH         | `ssh -i secrets/ssh/runner-vm_ed25519 ubuntu@192.168.178.34` |
| Listens on  | `22` (SSH), `8120` (its Komodo periphery, `192.168.178.34` only) |

## Cloud hosts (Oracle)

Off-NAS Oracle Cloud hosts on the tailnet. Full details in their runbooks/service docs.

| Host | Public IP | Tailnet IP | Role | Details |
| ---- | --------- | ---------- | ---- | ------- |
| `instance-20260417-1014` (AMD micro) | `198.51.100.10` | `100.64.0.12` | **Live public ingress** (nginx stream → NAS) | [services/micro-vps-ingress.md](services/micro-vps-ingress.md) |
| `instance-20260708-0942` (Ampere A1 `a1-matrix`) | `198.51.100.20` | `100.64.0.13` | **Matrix host** (Synapse + Postgres + Caddy `:80`/`:443`; mautrix bridges later) + **external watchdog** ([Uptime Kuma](services/a1-vps-kuma.md), tailnet `:3001` — moved off the ingress VPS 2026-08-21 so it does not share a failure domain with what it watches) + [Beszel agent](services/a1-vps-beszel-agent.md) (outbound to hub) + [Tor obfs4 bridge](services/a1-vps-tor-bridge.md) (public `:4443` obfs4 + `:9443` ORPort, metrics on tailnet `:9035`) + [Tor WebTunnel bridge](services/a1-vps-webtunnel.md) (a secret path behind this Caddy's `:443`, metrics on tailnet `:9036`) + [NTP Pool server](services/a1-vps-ntp.md) (public `:123/udp`, exporter on tailnet `:9037`) — [services/a1-vps-matrix.md](services/a1-vps-matrix.md) | [a1-provision](runbooks/setup-operations/a1-provision.md) → as-built; [matrix-deploy](runbooks/setup-operations/matrix-deploy.md) |

> SSH to the A1: `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20` (port **2222**,
> key-only — 22 is closed; use the **public** IP, tailscale SSH is ACL-blocked; key in the age vault
> `secrets.enc/ssh/ssh-a1-key.key.age`). This host is the **Matrix homeserver** (`a1-matrix`, renamed
> from `a1-ingress`), not ingress — the public front door stays on the AMD micro (`100.64.0.12`),
> which remains the value excluded by Caddy's `@lan` matcher.
>
> Matrix exposure: `matrix.example.com` **and** `element.example.com` (Element Web) are
> **Cloudflare grey-cloud (DNS-only)** to `198.51.100.20`; Caddy on the A1 terminates TLS.
> **Federation is delegated to `:443`** via `.well-known`, so **8448 is not exposed** — Matrix and
> SSH use only `80`/`443`/`2222` (both Oracle Security List and host iptables). Client + federation
> both ride `:443`. The [Tor bridge](services/a1-vps-tor-bridge.md) adds public `4443`/`9443` and the
> [NTP server](services/a1-vps-ntp.md) public `123/udp`, open in the Security List only: Docker DNATs
> published ports, so they never reach the `INPUT` chain. The [WebTunnel bridge](services/a1-vps-webtunnel.md)
> needs no port of its own: Caddy routes its secret path on `:443` over `proxy_a1-vps-webtunnel`, the
> A1's one cross-stack network, which `stacks/a1-vps-matrix` defines.

## Docker networks

| Network name  | Subnet        | Purpose                                        |
| ------------- | ------------- | ---------------------------------------------- |
| proxy_network | _(auto)_      | Shared by Caddy and CrowdSec; `victoriametrics` joins it to scrape CrowdSec |
| proxy_*       | _(auto)_      | Dedicated isolated proxy networks per stack (e.g. proxy_paperless) |
| observability_net | _(auto)_  | Internal network for Vector, VictoriaLogs, VictoriaMetrics, Grafana |
| authentik_net | _(auto)_      | Internal network for Authentik + Postgres      |
| media_net     | _(auto)_      | Shared by the five stacks split out of `mediaserver` — the **only** cross-stack network, see below |

> **`victoriametrics` joins a scraped stack's `proxy_*` network, never its internal one.** It is on
> `proxy_network` for `crowdsec:6060`, `proxy_authentik` for `server:9300`, `proxy_downloads` for
> the qBittorrent and SABnzbd exporters (`gluetun:9022`, `:9023`), `proxy_arr` for the
> `exportarr-*` sidecars (`:9707`) and `proxy_jellyfin` for `jellyfin-exporter:9594`, and each new scrape
> target adds one more join. Reaching a service over `authentik_net` or a stack's own `default`
> would put the metrics store on the same network as that stack's database — the `proxy_*` network
> is the one the service already exposes deliberately. See
> [services/observability.md](services/observability.md) → Adding a service.

> **`media_net` is a deliberate exception to the per-stack isolation model.** Splitting the old
> 15-service `mediaserver` stack ([STR-1](architecture-review-2026-08-20.md#str-1--split-the-15-service-mediaserver-stack))
> cut through connections that the *arr apps store in their own config databases, not in compose:
> `sonarr`/`radarr` reach qBittorrent as `gluetun:8082`, `prowlarr` reaches FlareSolverr as
> `gluetun:8191`, and Seerr reaches `sonarr:8989` / `radarr:7878`. `media_net` keeps those
> hostnames resolving across the new stack boundaries. Isolation is **unchanged versus before the
> split** — those containers already shared one network — but it is weaker than the per-stack
> ideal, and that is the price of the split.
>
> It is created out-of-band (`docker network create media_net`), not by a stack, because all five
> consumers declare it `external: true` and none of them can be guaranteed to deploy first.

## Exposed ports (LAN)

Keep this table up to date. Any port reachable from the LAN must be listed here.

| Port  | Protocol | Service                  | Stack       | Notes                                              |
| ----- | -------- | ------------------------ | ----------- | -------------------------------------------------- |
| 53    | TCP/UDP  | DNS (AdGuard Home)       | adguard     |                                                    |
| 80    | TCP      | HTTP reverse proxy       | caddy       | Incoming traffic for all `example.com` subdomains|
| 443   | TCP      | HTTPS reverse proxy      | caddy       | Incoming traffic for all `example.com` subdomains|
| 8443  | TCP      | HTTPS, PROXY-protocol    | caddy       | Only the VPS ingress forwards here (over Tailscale) so Caddy sees the real client IP; plain `:443` stays PROXY-free for LAN/tailnet clients |
| 8090  | TCP      | Beszel hub (WebSocket)   | beszel      | Bound to tailnet IP `100.64.0.11` only — for off-host agents (VPS) |
| 45876 | TCP      | Beszel agent             | beszel      | Host network mode                                  |
| 9999  | TCP      | Snowflake proxy metrics  | snowflake   | Host network mode; bound to the LAN IP only, for the `victoriametrics` scrape. The proxy's WebRTC UDP is outbound-initiated |
| 8120  | TCP      | Komodo periphery (HTTPS) | nas-periphery | Bound to the LAN IP only. Komodo Core connects inbound; noise-key auth plus `PERIPHERY_ALLOWED_IPS`. The two VPS peripheries bind `:8120` to their tailnet IPs instead, and `runner-vm-periphery` to the [runner VM](#runner-vm)'s `192.168.178.34` |
| 9998  | TCP      | Psiphon Conduit metrics  | conduit     | Host network mode; bound to the LAN IP only, for the `victoriametrics` scrape. The station's WebRTC UDP is outbound-initiated |

> `github-runner` exposes no ports — outbound only (GitHub, Komodo over the LAN). It runs in the [runner VM](#runner-vm), not on the NAS host.
>
> `romm` exposes no host port either — RomM's `:8080` is reached only through Caddy over
> `proxy_romm`. It does, however, add a **TrueNAS SMB share `roms`**
> (`\\192.168.178.111\roms` → `/mnt/data/romm/roms`) so native GameCube/Wii/Switch emulators on
> the client can read ROMs directly. That rides the existing SMB service (`:445`, a TrueNAS
> service, not a Docker stack — which is why it isn't a row above), alongside the
> `stefan`/`diana`/`shared` shares.
>
> **Public (internet) ports** live on the Oracle VPS, not the NAS: `:80/:443` (nginx stream) and
> SSH `:2222`. Over Tailscale the VPS forwards `:80` to the NAS `:80` and `:443` to Caddy's
> PROXY-protocol listener `:8443`. See [services/micro-vps-ingress.md](services/micro-vps-ingress.md).

## DNS / reverse proxy

> **Caddy replaced NPMplus on 2026-09-07** ([SVC-1](architecture-review-2026-08-20.md#svc-1--npmplus--caddy)).
> It owns `:80`/`:443`/`:8443` and serves every request. `stacks/npm/` was removed on 2026-09-07;
> the archived doc is [archive/npm.md](archive/npm.md). The policy carried over unchanged — today
> 21 LAN-only and 5 public names, same client-IP rule — but it is now
> [`stacks/caddy/Caddyfile`](../stacks/caddy/Caddyfile) rather than NPM UI state, so read
> [services/caddy.md](services/caddy.md) for the mechanics. Plan and execution record:
> [caddy-migration.md](runbooks/setup-operations/caddy-migration.md).

Services are exposed via **Caddy** under the domain `example.com`. Each service gets a subdomain (e.g. `service.example.com`) proxied to the container's internal port over its own dedicated, isolated `proxy_<stackname>` network (Hub and Spoke model). Direct LAN access via `http://192.168.178.111:<port>` is disabled for security, ensuring all traffic flows through Caddy and its per-host matchers.

> **No bootstrap UI port any more.** Portainer's `:31015` was the one infrastructure UI kept on a host
> port, for use before the proxy and DNS exist. It went with Portainer on 2026-09-17. Komodo Core has
> no host port. With Caddy or DNS down, deploy from the NAS instead: `docker compose up -d` in the
> periphery's clone at `/mnt/apps/komodo/repos/nas/stacks/<name>`
> ([komodo.md → Restart / redeploy](services/komodo.md#restart--redeploy)). Caddy has no UI, and its
> whole configuration is `stacks/caddy/Caddyfile` in this repo.
>
> **AdGuard has no permanent host port** — only `:53` (DNS) is published; its admin UI (container
> port `30004`) is reached through Caddy at `adguard.example.com`. For the very first bring-up,
> temporarily publish `30004:30004` in the stack, then remove it
> once the Caddy vhost exists. See the
> bootstrap note in [replicate-setup.md](runbooks/setup-operations/replicate-setup.md) (Phase 3).

Traffic from the public internet reaches Caddy via **Cloudflare → Oracle VPS front door**.
`*.example.com` is **proxied through Cloudflare** (orange-cloud): public DNS resolves to Cloudflare
anycast IPs, Cloudflare terminates the client TLS and **origin-pulls** to the **VPS public IP**
(`198.51.100.10`); the VPS nginx stream-forwards `:80/:443` to the NAS over **Tailscale**
(WireGuard) — the NAS needs no public IP. LAN/tailnet clients hit Caddy directly (AdGuard rewrites
the names to the NAS IP) and never touch Cloudflare or the VPS. Because Cloudflare fronts the
origin, a dropped SNI at the VPS surfaces as a **Cloudflare `525`** rather than a bare reset, and
anything Caddy answers is passed straight through. Because Cloudflare terminates that TLS, the peer
the VPS puts in the PROXY header is a Cloudflare edge address; Caddy recovers the visitor from
`CF-Connecting-IP` on `:8443` only — see [services/caddy.md](services/caddy.md) → Real client IP
behind Cloudflare. Details: [services/micro-vps-ingress.md](services/micro-vps-ingress.md).
Both layers are asserted every 6 h by
[`edge-access-policy.yml`](../.github/workflows/edge-access-policy.yml) — see the
[edge access policy probe runbook](runbooks/setup-operations/edge-access-policy-probe.md).

### Access control (who can reach each subdomain)

The VPS forwards internet `:443` only for an **SNI allowlist** of public hostnames
(`auth`/`files`/`immich`/`jellyfin`/`mealie` — see [services/micro-vps-ingress.md](services/micro-vps-ingress.md) → Security); all
other names are dropped at the VPS. The four orange-clouded names are forwarded **only when the peer
is a Cloudflare edge address**: `jellyfin` is gray-cloud, so its A record publishes the origin IP,
and without that gate anyone who resolved it could reach the other four directly and skip
Cloudflare entirely. As a second, independent layer, exposure is controlled per
host in the Caddyfile: LAN-only names carry an `@lan` matcher and `abort` everything else, which
closes the connection with no response (see [services/caddy.md](services/caddy.md) → Access control
model). A **new public service** therefore needs both: a `map` entry in
[`stacks/micro-vps-ingress/`](../stacks/micro-vps-ingress/) _and_ a Caddyfile vhost (for the name and
its `:8443` twin) that does **not** import `lan_only` — plus its name in the probe's `PUBLIC_HOSTS`.

- **Public, behind Authentik SSO** — `auth` (Authentik itself). Caddy proxies it to the Authentik
  embedded outpost (`authentik-server-1:9443` on `proxy_authentik`) and applies no access list of
  its own — auth is enforced at the upstream.
- **Public, app's own auth** — `immich`, `mealie` and `files` (proxied directly to the app; each
  authenticates via its own native Authentik OAuth/OIDC connector — see [immich](services/immich.md)
  / [mealie](services/mealie.md) / [files](services/files.md) — kept public so immich's mobile app
  and friends without VPN access can reach them). Caddy does not route through the Authentik
  outpost here; the app itself redirects the browser to Authentik. For `files` that is what lets
  its public share and upload links work at all — before the 2026-09-09 cutover the name went
  through the outpost to the old filebrowser, which could only approximate it with
  `skip_path_regex` holes ([migration runbook](runbooks/setup-operations/filebrowser-to-quantum.md)).
  **`immich` additionally blocks its password endpoints at the public edge** (since 2026-09-16),
  the same shape as `jellyfin` below: the `:8443` site block `403`s `POST /api/auth/login` and
  `/api/auth/admin-sign-up`, while `/api/oauth/*` (web **and** mobile app) and anonymous `/share/`
  links are not matched. LAN/tailnet `:443` keeps native password login.

> **Forward-auth is not used for any of these, and cannot be.** An Authentik proxy provider in
> front of `immich` or `jellyfin` would 302 every request, which their mobile/native clients and
> APIs cannot follow; excluding `/api/` to fix that excludes essentially the whole app. `files`
> was deliberately migrated *off* a proxy provider on 2026-09-09 for the same class of reason.
> What gates these apps instead is (a) the app's own OIDC login, (b) the Authentik **`nas-users`
> application binding** — [authentik.md → Application access](services/authentik.md#application-access-the-login-allowlist)
> — and (c) the edge `403`s on password endpoints.
- **Public web UI, SSO via plugin + edge login-block** — `jellyfin`. The web UI is public and logs
  in through Authentik via the `9p4/jellyfin-plugin-sso` plugin (web-UI only). Jellyfin keeps its
  native password login internally (Seerr + native apps need it), so Caddy **returns `403` at the
  public `:8443` edge** for the password endpoints (`/Users/AuthenticateByName`, the by-user-id
  `/Users/{id}/Authenticate`, and `/Users/Public`) — LAN/tailnet `:443` and Seerr's internal path
  are unaffected. `/sso/*` and `/QuickConnect/*` stay open. **`seerr` stays LAN-only.** Jellyfin is
  **gray-cloud (DNS-only)** at Cloudflare (video streaming — ToS §2.8), so the Caddy block is the sole
  edge guard. See [jellyfin-authentik-sso runbook](runbooks/setup-operations/jellyfin-authentik-sso.md).
- **LAN-only** (`@lan remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10` plus
  `not remote_ip 100.64.0.12`; everything else is `abort`ed) —
  the `172.16.25.1` entry is the Docker gateway, which is what Caddy sees for Kuma's internal
  checks; the `100.64.0.0/10` range is the Tailscale CGNAT range, so remote tailnet clients (subnet
  router runs with `--snat-subnet-routes=false`, preserving their real IP) pass
  the same as LAN. **The `not remote_ip 100.64.0.12` (VPS ingress tailnet IP) is what keeps these
  private**: the VPS forwards public `:443` to Caddy from its own tailnet IP, which is inside
  `100.64.0.0/10` — without that exclusion, every LAN-only admin UI would be reachable from the
  public internet. Unlike nginx's ordered `allow`/`deny`, a Caddy matcher is a set and the two
  clauses are evaluated together, so there is no ordering to get wrong. See
  [services/micro-vps-ingress.md](services/micro-vps-ingress.md) → Security. Covers everything else: `nas` (TrueNAS host web
  UI — not a Docker stack, proxied to the host over HTTPS), `grafana`
  (traffic and service analytics — see [services/observability.md](services/observability.md); it
  replaced the `goaccess` placeholder name on 2026-09-09), `adguard`,
  `homarr`, `komodo` (Komodo Core, the control plane), `kuma`, `beszel`, `paperless`, `seerr`,
  `games`, `questarr`, `romm`, `shelfmark`, and all *arr / download tools (`sonarr`,
  `radarr`, `bazarr`, `prowlarr`, `sabnzbd`, `qbittorrent`). This list is the one
  [`edge-access-policy.yml`](../.github/workflows/edge-access-policy.yml) asserts — keep them in step.

> Authentik authenticates `files` via an **OIDC provider** the app drives itself (Caddy → files),
> not forward-auth — so the `files` vhost looks "open" but is actually gated by SSO.
> `files` and other SSO-gated apps do not expose host ports, preventing authentication bypass.
> Who may complete that SSO is the `nas-users` policy binding, which covers all five applications —
> [authentik.md → Application access](services/authentik.md#application-access-the-login-allowlist).

## Remote Administration (VPN)

Remote access to LAN-only services (Komodo, TrueNAS UI, *arr apps) from
outside the home network is provided by **Tailscale**, with the **FritzBox
WireGuard VPN** kept as a fallback.

### Primary — Tailscale (subnet router)

A `tailscale` Docker stack on the NAS runs as a **subnet router** advertising
`192.168.178.0/24` into the tailnet. Any signed-in tailnet device (phone,
laptop) reaches the full LAN once the route is approved in the admin console.
Switched to Tailscale after recurring instability in the FritzBox WG forwarding
(packet loss on the FritzBox→LAN segment — see the incident reference). No LAN
port is exposed; Tailscale is outbound-only. Details + setup:
[services/tailscale.md](services/tailscale.md).

### Fallback — FritzBox WireGuard VPN

Hosted on the router itself, so it stays reachable **even when the NAS is
powered off** (Wake-on-LAN; the board has no IPMI) — the one case Tailscale can't cover, since
the subnet router runs on the NAS. Kept configured as a backup path; connecting
gives full `192.168.178.0/24` access.


## Adding a New Stack

Because of the Maximum Security "Hub and Spoke" networking model, adding a new web-facing stack
requires granting the edge proxy access to the new network. `stacks/caddy` owns every `proxy_*`
definition; every other stack consumes them as `external: true`.

1. Edit `stacks/caddy/docker-compose.yml`:
   - Add `- proxy_<newstack>` to the `caddy` service's `networks` list.
   - Add `proxy_<newstack>: \n    name: proxy_<newstack>` to the bottom `networks` block.
   - Both edits are required. Compose only creates a network that some service attaches to, so a
     definition nothing joins is silently skipped.
2. Create `stacks/<newstack>/docker-compose.yml`
   - Ensure its web container attaches to `- proxy_<newstack>`.
   - Add `proxy_<newstack>: \n    external: true` to the bottom `networks` block.
3. Create `docs/services/<newstack>.md` from template.
4. Add the vhost to `stacks/caddy/Caddyfile` — see [services/caddy.md](services/caddy.md).
5. Push: `deploy-stacks` redeploys `caddy` (creating the network) and creates the new stack.
6. Commit: `feat(stacks): add <newstack>`

> **If the new stack must resolve containers in another stack by name**, attach both to a shared
> external network — `media_net` is the existing example. Prefer not to: the per-stack `proxy_*`
> model exists so a compromise in one stack cannot reach another. Cross-stack hostnames configured
> inside an app's own UI are invisible to this repo and to CI, so they break silently.
