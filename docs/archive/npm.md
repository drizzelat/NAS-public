# Service: nginx Proxy Manager (npm)

> **Archived 2026-09-07.** The `npm` stack was deleted after Caddy took the edge; this file is
> kept for the bootstrap history and for a rollback that has to rebuild NPMplus from scratch.
> Nothing here describes anything running. Current edge: [caddy.md](../services/caddy.md).
> The data is still on disk at `/mnt/apps/npm/npm/data`, plus the ZFS snapshot
> `apps/npm@pre-caddy-2026-09-06`.

## Overview

nginx Proxy Manager (NPM) was the reverse proxy that exposed services to the internet under the `example.com` domain. The image is the **NPMplus** fork (bundled Anubis anti-bot + CrowdSec intrusion detection). Public internet traffic reached it from the **Oracle VPS** front door over **Tailscale** — see [micro-vps-ingress.md](../services/micro-vps-ingress.md).

> **Stopped since 2026-09-07 — this stack is the rollback, not the edge.** [Caddy](../services/caddy.md)
> serves every request now ([SVC-1](../architecture-review-2026-08-20.md#svc-1--npmplus--caddy)).
> The stack stays present-but-stopped in Portainer for the two-week soak, because starting it is
> the whole rollback: `/mnt/apps/npm/npm/data` holds NPMplus's entire configuration and nothing in
> the cutover touched it, nor the VPS, DNS, Cloudflare or Authentik. There is a pre-cutover
> snapshot at `apps/npm@pre-caddy-2026-09-06`. Everything below describes NPMplus as it was
> configured and as it comes back if started; the live edge is
> [caddy.md](../services/caddy.md). Removal is a post-soak PR — see the
> [migration plan](../runbooks/setup-operations/caddy-migration.md).

### Containers

| Container      | Role                                                |
| -------------- | --------------------------------------------------  |
| npm            | nginx Proxy Manager — reverse proxy + TLS + GoAccess|

`crowdsec` **moved to the `caddy` stack** at the cutover: stopping this stack stops it, and the
bouncer it serves is now Caddy's. Its bind mounts still live under `/mnt/apps/npm/crowdsec/`, so
nothing about the CrowdSec database or config moved with it. Portainer's *stored* compose for this
stack still contains the service, which is what makes the rollback a single Start.

> **Public ingress is external.** The VPS's nginx stream-forwards public `:80/:443` to this NAS's
> `0.0.0.0:80/443` over Tailscale (WireGuard). NPMplus publishes those ports on the host, so the
> tunnel lands on them directly — no in-stack tunnel client. See [micro-vps-ingress.md](../services/micro-vps-ingress.md).

## Stack

- **Stack folder:** `stacks/npm/`
- **Compose file:** `stacks/npm/docker-compose.yml`

## Access

| Field        | Value                            |
| ------------ | -------------------------------- |
| Admin UI URL | `https://npm.example.com` — **retired 2026-09-07**; no vhost, Caddy answers `404` |
| Admin Port   | 81 (published only while the stack runs; `http://192.168.178.111:81`) |
| HTTP Port    | 80 (incoming proxy traffic) — **Caddy holds it now** |
| HTTPS Port   | 443 (incoming proxy traffic) — **Caddy holds it now** |
| PROXY Port   | 8443 (VPS ingress) — **Caddy holds it now** |
| Auth         | Local admin user (NPM)           |
| GoAccess UI  | `https://goaccess.example.com` — `503` from Caddy; GoAccess lived inside this image |

Starting this stack while `caddy` runs cannot work: all four ports collide. The rollback is
`caddy` → Stop **then** `npm` → Start, in that order.

## Volumes / data

| Container path           | Host path                                | Purpose                        |
| ------------------------ | ---------------------------------------- | ------------------------------ |
| `/data` (npm)            | `/mnt/apps/npm/npm/data`                 | NPM config, certs, proxy hosts |
| `/data/goaccess/data`    | `/mnt/apps/npm/npm/data/goaccess/data`   | GoAccess persisted statistics  |

CrowdSec's three mounts moved to the `caddy` stack with the service; the host paths are unchanged
and still under `/mnt/apps/npm/crowdsec/`. See [caddy.md](../services/caddy.md) → Volumes.

## Environment variables

None required in Portainer (config is file-based).

## Traffic + blocked-traffic visibility

Two separate dashboards — they answer different questions and neither depends on the other:

| Question                           | Tool             | Where                                       |
| ---------------------------------- | ---------------- | ------------------------------------------- |
| What traffic is hitting the proxy? | GoAccess         | `https://goaccess.example.com` (in-image) |
| What did CrowdSec detect / block?  | CrowdSec Console | `app.crowdsec.net` (free tier, cloud)       |

### GoAccess

`GOA=true` (compose) starts the GoAccess build already inside the NPMplus image — no extra
container. It tails `/data/nginx/logs/access.log` (the same file CrowdSec parses) and serves a
real-time HTML report: requests over time, top hosts/URLs, status codes, bandwidth, referrers,
user agents, OS/browser breakdown.

- **Port 91 is HTTPS, not HTTP** (`listen 0.0.0.0:91 ssl` in the image's `goaccess.conf`). An NPM
  proxy host pointing at `http://npmplus:91` gets a `502`.
- **Websockets Support must be on** for the proxy host — the page is static HTML that live-updates
  over a WebSocket to the GoAccess unix socket. Without it the report renders once and freezes.
- **It cannot be embedded in Homarr.** The image sets
  `Content-Security-Policy: … frame-ancestors 'none'` on `:91`, so an iframe tile is blocked by the
  browser. Link out to it instead.
- **No host port**, per the repo's hub-and-spoke rule — it is reached only through NPM (which
  proxies to itself over `proxy_network`) behind the LAN-only access list.
- `GOACLA` overrides the GoAccess arguments; the image default is
  `--agent-list --real-os --double-decode --anonymize-ip --anonymize-level=1 --keep-last=30
  --with-output-resolver --no-query-string` (30 days retained, IPs anonymised).
- **GeoIP is optional and not persisted by default.** The MaxMind `GeoLite2-{Country,City,ASN}.mmdb`
  files go in `/opt/npmplus/goaccess/geoip`, which is **inside the image, not under the `/data`
  mount** — they are lost on every image pull unless you add a volume or the upstream
  `geoipupdate` sidecar. Skipped here; the report works without it, minus the country/ASN panels.
- Its DB (`/data/goaccess/data`) is inside the backed-up `/data` volume, so history survives
  restarts. It also grows — watch it if `--keep-last` is raised.

### CrowdSec Console

Enrollment only; no local dashboard container. See the
[crowdsec-console runbook](../runbooks/setup-operations/crowdsec-console.md). Shows alerts,
decisions, scenarios and per-IP detail for this LAPI. Note that until the
[bouncer](../runbooks/setup-operations/crowdsec-bouncer.md) is enabled, the Console shows
**detections, not blocks** — requests are still being served.

### Later: Grafana

Neither choice above forecloses it. CrowdSec exposes Prometheus metrics on `:6060`, and Console
enrollment does not touch that. Two things would need doing at that point: set
`prometheus.listen_addr` to `0.0.0.0` in `/mnt/apps/npm/crowdsec/config/config.yaml` (it defaults
to `127.0.0.1`, unreachable from another container), and add a separate nginx log exporter —
**NPMplus itself has no Prometheus endpoint**, which is exactly the gap GoAccess covers.

## Dependencies

- Docker network `proxy_network`. `stacks/caddy` **defines** all 17 `proxy_*` networks since
  2026-09-07; the identical block still here is vestigial and goes when this stack does. A
  rollback that starts this stack works either way — the networks already exist.
- **Public reachability** depends on the [VPS ingress](../services/micro-vps-ingress.md) + Tailscale: the VPS
  forwards internet `:80/:443` to this NAS over the tailnet. LAN/tailnet clients reach NPMplus
  directly and don't need the VPS.

## Access control model

The VPS ingress forwards `:443` only for an **SNI allowlist** of public hostnames
([micro-vps-ingress.md](../services/micro-vps-ingress.md) → Security); other hostnames never reach NPM from the internet.
On top of that, exposure is controlled **per host** with NPM Access Lists in the `location /`
block (`:80` is not SNI-filterable, and the lists also gate LAN/tailnet clients):

- **LAN-only** hosts use `allow 192.168.178.0/24; deny 100.64.0.12; allow 100.64.0.0/10; allow 172.16.25.1; deny all; satisfy any;` — non-LAN
  clients are refused. This covers all admin/*arr/download UIs. The `deny 100.64.0.12`
  (VPS ingress tailnet IP, **before** the tailnet allow) is **security-critical** — without it the
  VPS blind-forwards public traffic from an IP inside the allowed `100.64.0.0/10` range and every
  LAN-only UI becomes internet-reachable. See [micro-vps-ingress.md](../services/micro-vps-ingress.md) → Security.
  The ordering is asserted every 6 h from the VPS itself — see the
  [edge access policy probe runbook](../runbooks/setup-operations/edge-access-policy-probe.md).

- **Public** hosts use `allow all;`. Two patterns:
  - **Authentik proxy provider** — `files` is proxied to the Authentik embedded outpost
    (`authentik-server-1:9443`), which authenticates and relays to filebrowser. NPM `auth_request
    off` is intentional; SSO is enforced at the Authentik upstream, not in NPM.
  - **App's own auth** — `immich` and `mealie` are proxied directly and rely on their own native
    Authentik OAuth/OIDC connector (not an Authentik outpost proxy) — NPM `allow all;`, no
    `auth_request`, the app itself redirects to Authentik for login.

> **A refused request is `444`, and that comes from a per-host block, not from the Access List.**
> NPM's access module itself returns `403`; every LAN-only proxy host turns that into a dropped
> connection with `error_page 401 403 = @deny_drop; location @deny_drop { return 444; }` in its
> *Custom Nginx Configuration*. Until 2026-08-22 only 14 of the 21 carried it and the other 7
> answered a plain `403`, which leaks that the vhost exists; they were normalised by hand. It is
> pure UI state and nothing enforces it, so **add the block whenever you create a LAN-only proxy
> host** — and note that both answers mean denied, which is why
> [`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml) accepts either rather
> than turning a cosmetic regression into a red alert.

See the access-control table in [`docs/network.md`](../network.md) for the full per-host list.

## Notes

- CrowdSec collection installed: `ZoeyVid/npmplus` (pulls in `appsec-virtual-patching`,
  `appsec-generic-rules`, `base-http-scenarios`, `http-cve` and others as dependencies).
- **The collection must match the NPMplus log format.** NPMplus does not write upstream
  nginx-proxy-manager's format, so `crowdsecurity/nginx-proxy-manager` parsed **none** of it
  (6.95k lines read, 0 parsed — detection silently did nothing). `ZoeyVid/npmplus` ships the
  matching parser `ZoeyVid/npmplus-logs`, whose filter is
  `evt.Parsed.program startsWith 'npmplus'`. `evt.Parsed.program` comes from the
  acquisition's `labels.type`, so **both** must agree:
  `/mnt/apps/npm/crowdsec/config/acquis.d/npm.yaml` (a host file, not in this repo) needs
  `type: npmplus`. Verify with `cscli metrics show acquisition` — "Lines parsed" must be
  non-zero for `/var/log/npm/access.log`. **That acquisition was repointed at Caddy's log at the
  cutover** and this collection removed, so a rollback that must also restore detection has to
  put both back — see [caddy.md](../services/caddy.md) → Notes.
- Private sources are whitelisted (`crowdsecurity/whitelists` + `local/whitelist` cover
  `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`), so LAN clients and the Docker gateway
  `172.16.25.1` — which is what internal Uptime-Kuma checks look like to NPM — can never be
  banned. Keep those in place before touching the parser config.
- **Enforcement requires the bouncer.** CrowdSec only *detects* until the NPMplus bouncer is
  enabled and given a LAPI key — see [crowdsec-bouncer runbook](../runbooks/setup-operations/crowdsec-bouncer.md).
  The `LOGROTATE=true` prerequisite is set in compose; the bouncer key is a runtime secret.
- The Oracle VPS forwards public traffic to this NAS over Tailscale so the NAS doesn't need a public IP — see [micro-vps-ingress.md](../services/micro-vps-ingress.md).
- NPM handles TLS termination for `*.example.com` — configure Let's Encrypt DNS challenge in the NPM admin UI.
- **Dynamic upstream re-resolution (prerun hook).** npmplus generates `server <name>:<port>
  resolve;` upstreams, but its image hardcodes `resolver local=on ipv6=on;` with **no
  `valid=`** — so nginx honours the Docker-DNS TTL (~600s) and keeps proxying to a stale
  container IP for up to 10 min after a stack restart reshuffles IPs (→ 502 on jellyfin,
  *arr, etc.). `ENABLE_PRERUN=true` (compose) makes the entrypoint run
  `/data/prerun/10-resolver.sh`, which patches that line to `ipv6=off valid=10s` so nginx
  re-resolves every 10s and skips the dead Docker IPv6 (`fdd0::`) upstreams. The script is
  idempotent (image upgrades stay safe) and lives in the backed-up `/data` volume; a repo
  copy is kept at [`stacks/npm/prerun/10-resolver.sh`](../../stacks/npm/prerun/10-resolver.sh)
  for bare-metal rebuilds (place it at `/mnt/apps/npm/npm/data/prerun/` before first start).

## First-time UI setup

> **Bootstrap (chicken-and-egg).** You cannot reach `https://npm.example.com` yet — that
> hostname only resolves *after* NPM has a proxy host for it **and** AdGuard rewrites
> `*.example.com` → the NAS IP, neither of which exists on a fresh setup. During initial
> bring-up, open the admin UI by **host IP and port directly**: `http://192.168.178.111:81`.
> NPM (`:81`) and Portainer (`:31015`) are the only UIs with a permanent host port for exactly
> this reason — every app behind NPM has *no* host port. (AdGuard publishes only `:53`; its UI is
> reached via temporary `30004:30004` during bootstrap — see [adguard.md](../services/adguard.md).) Switch to
> the friendly hostname only after step 4 (proxy host) + AdGuard's DNS rewrite are in place.
>
> The **wildcard cert in step 2 still works during bootstrap**: the DNS-01 challenge sets TXT
> records at your domain's authoritative DNS (registrar/Cloudflare), so it does not depend on
> `*.example.com` resolving to the NAS.

After the stack is up, do this in the NPM admin UI (`http://192.168.178.111:81` during bootstrap; `https://npm.example.com` once proxied):

1. **First login** — default credentials `admin@example.com` / `changeme`. NPM forces you to set a real admin email and password on first login. Do it immediately.
2. **Wildcard TLS** — SSL Certificates → **Add** → Let's Encrypt, domain `*.example.com`, enable **Use a DNS Challenge**, pick the DNS provider and paste its API credentials. This one cert covers every host.
3. **Access Lists** — Access Lists → create a **LAN-only** list. In its nginx config use `allow 192.168.178.0/24; deny 100.64.0.12; allow 100.64.0.0/10; allow 172.16.25.1; deny all; satisfy any;` — **the `deny` must precede the CGNAT `allow`**, see the access-control model above. Assign it to every admin/*arr/download host.
4. **Proxy hosts** — Hosts → Proxy Hosts → **Add** per service: domain name, forward host/port (the container), enable **Block Common Exploits**, **Websockets**, SSL tab → select the wildcard cert + **Force SSL** + HTTP/2. On a **LAN-only** host also paste this into Advanced → *Custom Nginx Configuration*, so a denial drops the connection instead of answering `403` and confirming the vhost exists:

   ```nginx
   error_page 401 403 = @deny_drop;
   location @deny_drop {
     return 444;
   }
   ```

5. **filebrowser (Authentik forward-auth)** — on the `files.example.com` proxy host, Advanced tab: add the `location /` block that proxies to the Authentik embedded outpost (`authentik-server-1:9443`) with `auth_request off` (SSO is enforced upstream). See the access-control model above and [authentik doc](../services/authentik.md).
6. **Public vs LAN** — set each host's access per the table in [`docs/network.md`](../network.md): public hosts `allow all;`, everything else the LAN-only list.
7. **CrowdSec enforcement** — detection is on by default; turn it into blocking by enabling the NPMplus bouncer with a LAPI key — see [crowdsec-bouncer runbook](../runbooks/setup-operations/crowdsec-bouncer.md).
8. **GoAccess proxy host** — Hosts → Proxy Hosts → **Add**: domain `goaccess.example.com`,
   scheme **https**, forward host `npmplus`, port `91`, **Websockets Support on**, wildcard cert +
   Force SSL, and the LAN-only Access List. Scheme `http` or websockets off are the two ways this
   silently fails — see the GoAccess section above.
9. **CrowdSec Console** — enroll the LAPI for the hosted alerts/decisions dashboard, see the
   [crowdsec-console runbook](../runbooks/setup-operations/crowdsec-console.md).

## Operations

> Restart/redeploy go through **Portainer**, not host `docker` — the `truenas_admin` SSH user has no Docker socket access. Manual webhook fire: `curl -k -X POST https://192.168.178.111:31015/api/stacks/webhooks/<uuid>` (UUID from `scripts/portainer-migrate/read-webhooks.ps1`).

### Restart / redeploy

- Portainer → Stacks → `npm` → **Restart** or **Pull and redeploy**. This is the **single front door** — a restart briefly drops all proxied traffic.
- Or push to `stacks/npm/` → runner fires the stack webhook ([webhook runbook](../runbooks/setup-operations/portainer-webhook-deploy.md)).

### Upgrade

- **Manual.** `npmplus` and `crowdsec` are both `latest@sha256:…` (digest-held) — critical reverse proxy, so updates are deliberate. Bump: pull `latest` → read new digest → edit `image:` → commit/PR → redeploy; check NPMplus release notes first. CrowdSec collections persist in the config volume.

### Restore from backup

1. Stop the `npm` stack in Portainer.
2. Restore `apps/npm/npm/data` (proxy hosts, certs, **access lists**) and `apps/npm/crowdsec/{data,config}` from a ZFS snapshot or from Hetzner.
3. Start the stack.

### Common failures

- **Everything externally unreachable** → NPM is the single front door. If the `npm` container is down, all public hosts and proxied LAN hostnames fail. If *only public* access is down (LAN fine), suspect the **VPS ingress / Tailscale backhaul** — check the VPS ([micro-vps-ingress.md](../services/micro-vps-ingress.md)) and the NAS `tailscale` subnet router. See [cert/DNS/proxy runbook](../runbooks/incident-response/cert-dns-proxy-outage.md).
- **TLS cert expired / renewal failing** → Let's Encrypt DNS-01 challenge in the NPM admin UI; details in the [cert/DNS/proxy runbook](../runbooks/incident-response/cert-dns-proxy-outage.md).
- **A legitimate LAN client gets `444` or `403`** → wrong NPM Access List; see the LAN-only rule in
  the access-control model above.
- **An IP is unexpectedly blocked** → CrowdSec decision; list/remove with `cscli decisions list` / `cscli decisions delete`. Enforcement requires the bouncer — see [crowdsec-bouncer runbook](../runbooks/setup-operations/crowdsec-bouncer.md).
- **GoAccess page loads but never updates** → Websockets Support is off on the `goaccess` proxy
  host. The initial HTML is static; all live data arrives over the WebSocket.
- **GoAccess `502`** → proxy host scheme is `http`. Container port 91 is HTTPS-only.
- **GoAccess report is empty** → nothing has hit the proxy since `GOA=true` was first enabled, or
  `/data/nginx/logs/access.log` is missing (same file CrowdSec reads — if `cscli metrics show
  acquisition` is also at zero lines, the log path is the shared cause, not GoAccess).
- **502 on one or more hosts after a stack restart** → nginx cached a stale upstream IP after a
  container-IP reshuffle. The `ENABLE_PRERUN` resolver patch (see Notes) caps this at ~10s; if it
  recurs, confirm `ENABLE_PRERUN=true` is set and `/data/prerun/10-resolver.sh` exists and ran
  (its `[prerun 10-resolver]` line is in the npm container log). Immediate clear: restart the `npm` stack.

## Last updated

2026-09-07
