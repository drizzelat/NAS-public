# Tailscale subnet router (NAS)

## Overview

Tailscale **subnet router** running on the NAS host as native `tailscaled` (NixOS
`services.tailscale`; until the NixOS PR #570 merges, its config is on branch `plt-1-nixos-draft`).
It was the Komodo stack `tailscale` until the NixOS cutover; that stack is gone.

It advertises the home LAN
(`192.168.1.0/24`) into the tailnet, so remote devices (phone, laptop) reach
LAN-only services — Komodo, AdGuard, the *arr apps — over an
encrypted WireGuard-based mesh without the FritzBox WireGuard VPN.

This is the **primary** remote-access path. The FritzBox WireGuard VPN is kept
as a **fallback** because it runs on the router and stays reachable when the NAS
is powered off (Wake-on-LAN — the board has no IPMI). See network.md.

**Second consumer of this tailnet: the public ingress.** The Oracle VPS front door reaches Caddy's
`:8443` listener over this same tailnet (VPS node `100.64.0.12` → NAS peer `nas` `100.64.0.11`). So if this
subnet router / node goes down, **public sites go down too**, not just remote admin. See
micro-vps-ingress.md.

## Host config

- **Where:** the NixOS module `services.tailscale` in the host config's `network.nix`: hostname
  `nas`, `--advertise-routes=192.168.1.0/24`, `--accept-dns=false`, `--snat-subnet-routes=false`,
  `useRoutingFeatures = "server"` (IP forwarding), state dir `/mnt/apps/tailscale`.
- **Unit:** `tailscaled.service`, ordered after the pools (`nas-pools.target`) and with
  `TS_DEBUG_FIREWALL_MODE=nftables`. The firewall trusts `tailscale0`.
- **Deploy:** with the host config (`nixos-rebuild`, or the pull-deploy once it is on). Not Komodo.

## Access

| Field | Value                                                          |
| ----- | -------------------------------------------------------------- |
| URL   | n/a — no web UI. Managed at <https://login.tailscale.com/admin>; the ACL belongs in `tailscale/policy.hujson` (runbook) |
| Port  | None on the LAN. Outbound UDP 41641 + DERP relays only         |
| Auth  | Tailscale account; the node identity lives in its state dir    |

The NAS appears in the tailnet as node **`nas`** at a `100.x.y.z` address. Once
the advertised route is approved, the whole `192.168.1.0/24` is reachable from
any tailnet device.

## State

`/mnt/apps/tailscale` (dataset `apps/tailscale`): node identity and keys. The same directory the
container used, so the node kept its name and tailnet IP `100.64.0.11` across the cutover. Not in
the offsite backup (a fresh login re-registers the node).

## Dependencies

- Host IP forwarding (`useRoutingFeatures = "server"`) — forwards tailnet traffic into the LAN.
- AdGuard stays the LAN DNS resolver (`--accept-dns=false`).
- The pools: no tailnet when `apps` fails to import. LAN SSH still works.

## Notes

- **It must run in the host network namespace**, as it does natively. In a container on its own
  bridge a tailnet client query to `192.168.1.111:53` (AdGuard) hits Docker's **UDP hairpin-NAT
  bug** and is dropped; that is why the old container ran with `network_mode: host`, and why
  **Split DNS / AdGuard resolution over Tailscale** depends on it.
- **No LAN port exposed** — Tailscale is outbound-only (UDP 41641 + DERP), so
  nothing is added to the exposed-ports table in network.md.
- **Subnet-route SNAT is disabled** (`--snat-subnet-routes=false`). Default-on
  SNAT masquerades tunnel traffic to the NAS IP, which made the edge proxy see a
  Docker gateway instead of the client and refuse every LAN-only service. With SNAT
  off, Caddy sees the real tailnet IP, and `100.64.0.0/10` is in its `@lan`
  matcher. **Cost:** reaching non-NAS LAN hosts over Tailscale needs a static route
  `100.64.0.0/10 → 192.168.1.111` on the FritzBox (LAN devices' default gw) so
  their replies find their way back. NAS-hosted services need nothing extra.
- **`--accept-dns=false`** — without it tailscaled would rewrite the host's resolver
  config and break NAS DNS.
- Host-down case: NAS off → no Tailscale. Use the FritzBox WG fallback then.
- **Tagged nodes need explicit ACL grants to reach user devices.** The Ampere A1
  (`tag:a1-matrix`) is a tagged node; the NAS is user-owned/untagged. Tagged nodes
  get **no** default access to user devices, so a1→nas data traffic is ACL-dropped
  even with the tunnel up. Symptom: `tailscale ping` succeeds (WireGuard-layer disco,
  ignores ACL) but TCP `i/o timeout`s. Grant it explicitly in
  [`tailscale/policy.hujson`](../tailscale/policy.hujson), e.g.
  `{"action":"accept","src":["tag:a1-matrix"],"dst":["100.64.0.11:<port>"]}`. The A1 has no such
  grant today: the NAS scrapes it, not the other way round.

## First-time setup

Only needed for a new node; the cutover kept the existing one.

1. **Dataset** `apps/tailscale` (`/mnt/apps/tailscale`) for the state dir.
2. **Log in** on the host: `sudo tailscale up` and open the printed URL, or use a one-off auth key
   from the admin console (Settings → Keys, *reusable: off*, *ephemeral: off*):
   `sudo tailscale up --auth-key=<key>`. The flags above come from the host config.
3. **Approve the subnet route** — admin console → Machines → `nas` → **…** →
   *Edit route settings* → enable `192.168.1.0/24`.
4. **Disable key expiry** for the `nas` node (Machines → `nas` → *Disable key
   expiry*) so the router doesn't drop off after 90 days.
5. **Client** — install Tailscale on phone/laptop, sign in, enable *Use
   subnet routes* (Android: on by default; iOS/desktop: toggle in settings).
6. **DNS (so `*.example.com` resolves)** — admin console → **DNS** →
   *Nameservers* → Add → `192.168.1.111`, *Restrict to domain* `example.com`
   (Split DNS). On each client enable *Use Tailscale DNS* (`tailscale set
   --accept-dns=true`). Requires the host network namespace — see Notes.
7. **Allow the tailnet at the edge** — already in the repo: every LAN-only vhost in
   [`stacks/caddy/Caddyfile`](../stacks/caddy/Caddyfile) matches `100.64.0.0/10`
   (the Tailscale CGNAT range) minus the ingress VPS's own tailnet IP. It only works
   because `--snat-subnet-routes=false` (set in the host config) lets Caddy see the real
   tailnet IP.
8. **Test** — from a remote client (mobile data, not home wifi), open
   `https://komodo.example.com` / `https://nas.example.com`. Once
   confirmed, the FritzBox WG is fallback-only.

## Operations

### Restart

- `sudo systemctl restart tailscaled`; status with `tailscale status` and
  `journalctl -u tailscaled`.

### Upgrade

- The version comes from the host config's `nixpkgs` input (`flake.lock`), not an image pin.
  Updating the lock updates tailscaled with the rest of the host. It carries the public ingress,
  so check `tailscale status` and a public site after the switch. Rollback = the previous
  generation (`nixos-rebuild switch --rollback`).

### Restore from backup

1. `sudo systemctl stop tailscaled`.
2. Restore `/mnt/apps/tailscale` from a ZFS snapshot of `apps` — **or** just log in again (the node
   re-registers; approve its route and disable key expiry again).
3. `sudo systemctl start tailscaled`.

### Common failures

- **Route not reachable from tailnet** → subnet route not approved in admin
  console (step 3), or client has *Use subnet routes* off.
- **Node dropped off after weeks** → key expiry not disabled (step 4).
- **`*.example.com` won't resolve over Tailscale, but the raw IP works**
  (Tailscale health: *can't reach the configured DNS servers*; client `tailscale
  dns status` missing the `example.com` split route) → seen when tailscaled ran
  in a bridged container: UDP/53 to AdGuard on the NAS's own published port dies in
  Docker's hairpin-NAT (see Notes). Natively it cannot happen; check AdGuard itself.
- **`ERR_HTTP2_PROTOCOL_ERROR` on every proxied service over the tunnel** (raw IP /
  DNS fine, HTTP/2 web pages fail) → tailscaled ran in **iptables-legacy** while
  the host + Docker use **nftables** — a second firewall backend on the FORWARD
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
  is still refused if the range is missing.
- **NAS powered off** → no Tailscale; fall back to FritzBox WG.
- **A remote job over the tailnet dies part-way through, and the NAS side reports
  no error of its own** → in the container era this was tailscaled OOM-killed inside its memory
  limit (2026-09-25, a dump streamed over `ssh://a1-docker`, whose alias resolves to the A1's
  tailnet address). Natively there is no limit; still check
  `sudo journalctl -k --since "<the run>" | grep -E "Killed process.*tailscaled"`.
