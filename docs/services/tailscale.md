# Service: Tailscale

## Overview

Tailscale **subnet router** running on the NAS. It advertises the home LAN
(`192.168.178.0/24`) into the tailnet, so remote devices (phone, laptop) reach
LAN-only services — Komodo, TrueNAS UI, AdGuard, the *arr apps — over an
encrypted WireGuard-based mesh without the FritzBox WireGuard VPN.

This is the **primary** remote-access path. The FritzBox WireGuard VPN is kept
as a **fallback** because it runs on the router and stays reachable when the NAS
is powered off (Wake-on-LAN — the board has no IPMI). See [network.md](../network.md).

**Second consumer of this tailnet: the public ingress.** The Oracle VPS front door reaches Caddy's
`:8443` listener over this same tailnet (VPS node `100.64.0.12` → NAS peer `nas` `100.64.0.11`). So if this
subnet router / node goes down, **public sites go down too**, not just remote admin. See
[micro-vps-ingress.md](micro-vps-ingress.md).

## Stack

- **Stack folder:** `stacks/tailscale/`
- **Compose file:** `stacks/tailscale/docker-compose.yml`
- **Deploy:** Komodo Stack `tailscale` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                                                          |
| ----- | -------------------------------------------------------------- |
| URL   | n/a — no web UI. Managed at <https://login.tailscale.com/admin> |
| Port  | None on the LAN. Outbound UDP 41641 + DERP relays only         |
| Auth  | Tailscale account; node joins via `TS_AUTHKEY`                 |

The NAS appears in the tailnet as node **`nas`** at a `100.x.y.z` address. Once
the advertised route is approved, the whole `192.168.178.0/24` is reachable from
any tailnet device.

## Volumes / data

| Container path       | Host path             | Purpose                    |
| -------------------- | --------------------- | -------------------------- |
| `/var/lib/tailscale` | `/mnt/apps/tailscale` | Node state / identity keys |

## Environment variables

| Variable     | Description                                                              |
| ------------ | ----------------------------------------------------------------------- |
| `TS_AUTHKEY` | One-off auth key from admin console (Settings → Keys). Vault → Komodo Variable `TAILSCALE__TS_AUTHKEY`. |

Other Tailscale settings (`TS_ROUTES`, `TS_USERSPACE`, etc.) are baked into the
compose file, not env vars.

## Dependencies

- `network_mode: host` — **required** (see Notes), not just convenient.
- `cap_add: NET_ADMIN` + `/dev/net/tun` — kernel networking for subnet routing.
- Host `net.ipv4.ip_forward=1` (already set on the NAS) — forwards tailnet
  traffic into the LAN. No per-container `sysctls` block: it's rejected in the
  host netns, and the host already forwards.
- AdGuard stays the LAN DNS resolver (`--accept-dns=false`).

## Notes

- **Host networking is required.** On its own bridge the subnet router cannot
  DNS-forward to a port published on its *own* host: a tailnet client query to
  `192.168.178.111:53` (AdGuard) hits Docker's **UDP hairpin-NAT bug** — the
  reply returns with the container source instead of `.111` and is dropped (TCP
  to the same host survives it, UDP does not). In the host netns the forward to
  `.111:53` is a local delivery and works. This is why **Split DNS / AdGuard
  resolution over Tailscale only works in host mode.**
- **No LAN port exposed** — Tailscale is outbound-only (UDP 41641 + DERP), so
  nothing is added to the exposed-ports table in [network.md](../network.md).
- **Subnet-route SNAT is disabled** (`--snat-subnet-routes=false`). Default-on
  SNAT masquerades tunnel traffic to the NAS IP, which made the edge proxy see a
  Docker gateway instead of the client and refuse every LAN-only service. With SNAT
  off, Caddy sees the real tailnet IP, and `100.64.0.0/10` is in its `@lan`
  matcher. **Cost:** reaching non-NAS LAN hosts over Tailscale needs a static route
  `100.64.0.0/10 → 192.168.178.111` on the FritzBox (LAN devices' default gw) so
  their replies find their way back. NAS-hosted services need nothing extra.
- **`--accept-dns=false` matters more in host mode** — without it tailscaled
  would rewrite the *host's* `/etc/resolv.conf` and break NAS DNS.
- **No `no-new-privileges`** — tailscaled rewrites iptables/routing, same reason
  gluetun is excluded.
- Host-down case: NAS off → this container is off → no Tailscale. Use the
  FritzBox WG fallback then.
- **Tagged nodes need explicit ACL grants to reach user devices.** The Ampere A1
  (`tag:a1-matrix`) is a tagged node; the NAS is user-owned/untagged. Tagged nodes
  get **no** default access to user devices, so a1→nas data traffic is ACL-dropped
  even with the tunnel up. Symptom: `tailscale ping` succeeds (WireGuard-layer disco,
  ignores ACL) but TCP `i/o timeout`s. Grant it explicitly in the admin console —
  e.g. the A1 Beszel agent needs `{"action":"accept","src":["tag:a1-matrix"],
  "dst":["100.64.0.11:8090"]}`. See
  [a1-vps-beszel-agent.md](a1-vps-beszel-agent.md).

## First-time setup

0. **Create the dataset** — TrueNAS → Datasets → `apps` → add child `tailscale`
   (host path `/mnt/apps/tailscale`) for the node state bind mount.
1. **Admin console → Settings → Keys → Generate auth key.** Make it
   *reusable: off*, *ephemeral: off*. Optionally pre-approve tags. Copy it.
2. **Vault** → `scripts/secrets.sh edit tailscale`, set `TS_AUTHKEY=<key>`, then
   `scripts/secrets.sh push tailscale` (writes the Komodo Variable and deploys the Komodo Stack).
3. **Approve the subnet route** — admin console → Machines → `nas` → **…** →
   *Edit route settings* → enable `192.168.178.0/24`.
4. **Disable key expiry** for the `nas` node (Machines → `nas` → *Disable key
   expiry*) so the router doesn't drop off after 90 days.
5. **Client** — install Tailscale on phone/laptop, sign in, enable *Use
   subnet routes* (Android: on by default; iOS/desktop: toggle in settings).
6. **DNS (so `*.example.com` resolves)** — admin console → **DNS** →
   *Nameservers* → Add → `192.168.178.111`, *Restrict to domain* `example.com`
   (Split DNS). On each client enable *Use Tailscale DNS* (`tailscale set
   --accept-dns=true`). Requires the stack in **host mode** — see Notes.
7. **Allow the tailnet at the edge** — already in the repo: every LAN-only vhost in
   [`stacks/caddy/Caddyfile`](../../stacks/caddy/Caddyfile) matches `100.64.0.0/10`
   (the Tailscale CGNAT range) minus the ingress VPS's own tailnet IP. It only works
   because `--snat-subnet-routes=false` (set in the stack) lets Caddy see the real
   tailnet IP.
8. **Test** — from a remote client (mobile data, not home wifi), open
   `https://komodo.example.com` / `https://nas.example.com`. Once
   confirmed, the FritzBox WG is fallback-only.

## Operations

> Restart/redeploy go through **Komodo** (Stack `tailscale`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `tailscale` → **Deploy** (or **Restart**).
- Or push to `stacks/tailscale/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Image is **version-pinned** to a fixed `tailscale` `tag@sha256:…` (exact version in the
  compose file). Renovate opens the PR and the review sweep merges it when cleared; it runs with
  NET_ADMIN and carries the public ingress, so read the notes before hand-merging a
  `RISK: REVIEW`. Rollback = revert the commit + redeploy.

### Restore from backup

1. Stop the `tailscale` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/tailscale` (node identity/state) from a ZFS snapshot of `apps`
   or from Hetzner — **or** just re-auth with a fresh `TS_AUTHKEY` (the node
   re-registers; approve its route again).
3. Start the stack.

### Common failures

- **Route not reachable from tailnet** → subnet route not approved in admin
  console (step 3), or client has *Use subnet routes* off.
- **Node dropped off after weeks** → key expiry not disabled (step 4).
- **`*.example.com` won't resolve over Tailscale, but the raw IP works**
  (Tailscale health: *can't reach the configured DNS servers*; client `tailscale
  dns status` missing the `example.com` split route) → the stack is in bridge
  mode, not `network_mode: host`. UDP/53 to AdGuard on the NAS's own published
  port dies in Docker's hairpin-NAT. Redeploy in host mode (see Notes). Verify
  the fix from the host: `docker exec tailscale nslookup test.example.com
  192.168.178.111` should return `192.168.178.111`.
- **`ERR_HTTP2_PROTOCOL_ERROR` on every proxied service over the tunnel** (raw IP /
  DNS fine, HTTP/2 web pages fail) → tailscaled ran in **iptables-legacy** while
  TrueNAS + Docker use **nftables** — a second firewall backend on the FORWARD
  path, and the legacy `ts-forward` chain had no MSS clamp, so large HTTP/2
  frames break on the 1280-MTU tunnel. Fixed by `TS_DEBUG_FIREWALL_MODE=nftables`
  (aligns backends, installs clamp-MSS-to-PMTU). Verify on host:
  `sudo nft list ruleset | grep -i maxseg` shows a clamp rule, and tailscaled
  logs `router: default choosing nftables`.
- **Every LAN-only service is refused instantly over the tunnel** (empty reply;
  raw IP + DNS fine; the Caddy access log shows a `172.16.x` gateway as the
  client) → the tailnet source was masqueraded by `--snat-subnet-routes`, so it
  fails the `@lan` matcher. Fixed by `--snat-subnet-routes=false` (real tailnet IP
  visible) **plus** `100.64.0.0/10` in `@lan`. Both are required — the flag alone
  is still refused if the range is missing. (Do **not** chase the docker
  `userland-proxy`; on TrueNAS 25.04 `daemon.json` is middleware-managed and edits
  get regenerated away.)
- **NAS powered off** → no Tailscale; fall back to FritzBox WG.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
