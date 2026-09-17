# Runbook: Tailscale remote access — design & gotchas

Why the Tailscale remote-access config is the way it is, and how to localise a break. Tailscale is
the primary remote path; FritzBox WireGuard is **kept as a host-down fallback**. End-state config
lives in [services/tailscale.md](../../services/tailscale.md) and
[stacks/tailscale/](../../../stacks/tailscale/docker-compose.yml).

## The tunnel request path (localise a break fast)

```text
Tailscale client ──(WireGuard tunnel)──► nas subnet router (container, host net)
        │                                        │
        │ DNS: example.com split → .111        ├─ subnet route 192.168.178.0/24
        ▼                                        ▼
   100.100.100.100 (MagicDNS)            AdGuard :53 / Caddy :443 (on the NAS itself)
```

Everything terminates on the **NAS's own IP** (`.111`). That single fact drives most of the config
below: a container reaching services published on *its own host* behaves differently from reaching
another host.

## Why the config is what it is

### `network_mode: host` — UDP/53 to AdGuard works

AdGuard's `:53` is published on the NAS's own LAN IP. In bridge mode, DNS from the subnet router to
`.111:53` dies in Docker's **UDP hairpin-NAT** (AdGuard's reply returns with the container source
instead of `.111` and is dropped; TCP survives, UDP doesn't). Running the subnet router in
`network_mode: host` makes the forward to `.111:53` a local delivery, so it works. In host netns
drop the `sysctls` block (rejected there; the host already has `net.ipv4.ip_forward=1`) and keep
`--accept-dns=false` so tailscaled doesn't clobber the host's `resolv.conf`.

> Symptom if this regresses: `*.example.com` won't resolve over the tunnel but the raw IP works
> (Tailscale health: *can't reach the configured DNS servers*; `tailscale dns status` missing the
> `example.com` split route). Verify from the host: `docker exec tailscale nslookup
> test.example.com 192.168.178.111` should return `192.168.178.111`.

### `TS_DEBUG_FIREWALL_MODE=nftables` — single firewall backend + MSS clamp

TrueNAS + Docker run on **nftables**; without this flag tailscaled picks **iptables-legacy**, a
second backend on the same FORWARD path, and its `ts-forward` chain has **no MSS clamp** — so large
HTTP/2 frames break on the 1280-MTU tunnel (`ERR_HTTP2_PROTOCOL_ERROR` on every proxied service, raw IP
+ DNS fine). Forcing `nftables` aligns backends and installs the clamp-MSS-to-PMTU rule. Verify on
host: `sudo nft list ruleset | grep -i maxseg` shows a clamp rule; tailscaled logs `router: default
choosing nftables`.

### `--snat-subnet-routes=false` + `100.64.0.0/10` in `@lan` — real tailnet source IP

Tailscale's `--snat-subnet-routes` (default on) masquerades tunnel clients as a Docker gateway, so
the edge's LAN-only rule refused them (under NPMplus a `444`, which the browser showed as
`ERR_HTTP2_PROTOCOL_ERROR` / instant reset). Turning SNAT off lets Caddy see the real
`100.64.0.0/10` tailnet source, which its `@lan` matcher admits. **Both are required** — the flag
alone is still refused if the range is missing.

- **Caveat:** with SNAT off, reaching **non-NAS** LAN hosts over Tailscale needs a route
  `100.64.0.0/10 → 192.168.178.111` on the FritzBox (LAN devices' default gw). NAS-hosted services
  need nothing extra.
- **Not used:** disabling docker `userland-proxy` would preserve the source via kernel DNAT, but on
  TrueNAS 25.04 `/etc/docker/daemon.json` is middleware-managed (regenerated), so the edit gets
  clobbered. The SNAT-off path is GitOps-native and needs no daemon change.

### `not remote_ip 100.64.0.12` — VPS ingress overlap

`100.64.0.0/10` (RFC 6598 CGNAT space) is **not internet-routable** and only authenticated tailnet
devices emit those addresses — so allow-listing the range is otherwise safe. But the **VPS ingress
forwards public traffic from its own tailnet IP `100.64.0.12`, which *is* inside `100.64.0.0/10`**,
so the range alone would expose LAN-only hosts to the internet. Every LAN-only vhost's `@lan`
matcher therefore excludes the VPS IP with `not remote_ip 100.64.0.12` — a set, not an ordered
list, so there is no ordering to get wrong (NPMplus needed the `deny` *before* the `allow`). See
[micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Security.

## End-state config

`stacks/tailscale/docker-compose.yml`, key bits:

- `network_mode: host` — UDP/53 to AdGuard works (no hairpin).
- `cap_add: NET_ADMIN`, `/dev/net/tun`, no `sysctls`, no `no-new-privileges`.
- `TS_USERSPACE=false`, `TS_ROUTES=192.168.178.0/24`.
- `TS_DEBUG_FIREWALL_MODE=nftables` — single firewall backend.
- `TS_EXTRA_ARGS=--accept-dns=false --snat-subnet-routes=false`.

Plus, **not in the repo** (console / UI state):

- Admin console: route `192.168.178.0/24` approved, key expiry disabled, Split DNS
  `example.com → 192.168.178.111`.
- (In git, for reference) Caddy's `@lan`: `remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10`
  plus `not remote_ip 100.64.0.12` — [`stacks/caddy/Caddyfile`](../../../stacks/caddy/Caddyfile).
- Client: *Use Tailscale DNS* + *use subnet routes* on.
- Node auth: deploy with `TS_AUTHKEY=""` and open the interactive auth URL from the container logs
  (or set a real key in Portainer). Node state persists in `/mnt/apps/tailscale`.

## Verify

- [ ] `tailscale dns status` on the client lists `example.com → 192.168.178.111`.
- [ ] `nslookup portainer.example.com` over the tunnel → `192.168.178.111`.
- [ ] A LAN-only service loads over the tunnel (no empty reply / HTTP2 error).
- [ ] The Caddy access log (`/mnt/apps/caddy/logs/access.log`) shows the real `100.x` tailnet IP for tunnel requests.
- [ ] FritzBox WG still connects (fallback intact).
