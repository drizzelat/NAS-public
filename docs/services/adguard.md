# Service: AdGuard Home

## Overview

AdGuard Home is a network-wide DNS server and ad/tracker blocker. It acts as the primary DNS resolver for the LAN, filtering ads and tracking domains before they reach devices.

## Stack

- **Stack folder:** `stacks/adguard/`
- **Compose file:** `stacks/adguard/docker-compose.yml`
- **Deploy:** Komodo Stack `adguard` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field    | Value                              |
| -------- | ---------------------------------- |
| URL      | `https://adguard.example.com`    |
| Port     | 53 TCP/UDP (DNS), published on the LAN IP only (`192.168.178.111:53`) — only host-published port. Web UI is container port `30004`, reached via Caddy (no host mapping). |
| Auth     | Local admin user                   |

## Volumes / data

| Container path            | Host path                  | Purpose              |
| ------------------------- | -------------------------- | -------------------- |
| `/opt/adguardhome/conf`   | `/mnt/apps/adguard/config` | Configuration files  |
| `/opt/adguardhome/work`   | `/mnt/apps/adguard/workdir`| Working data / stats |

## Environment variables

| Variable | Description              |
| -------- | ------------------------ |
| `TZ`     | Timezone (set to Etc/UTC)|

## Dependencies

None.

## Notes

- The web UI listens on 30004 (not the default 80/3000). It has no host mapping, so the port only
  matters as Caddy's upstream (`http://adguard:30004`).
- `NET_BIND_SERVICE` capability is required to bind to port 53.
- `--no-check-update` flag disables the built-in update checker (updates are handled manually).
- Pinned to static IP `172.16.25.3` on the `proxy_adguard` network so other containers can use it as a resolver directly (e.g. Kuma's `dns:`), bypassing Docker UDP hairpin NAT on the published host port. Don't change this without also updating `stacks/kuma/docker-compose.yml`.
- That static only holds because `proxy_adguard` pins its subnet **and** confines dynamic
  allocation to `172.16.25.128/25` (`ip_range` in [`stacks/caddy/docker-compose.yml`](../../stacks/caddy/docker-compose.yml),
  which defines every `proxy_*` network). Without it, Docker hands out `.2`, `.3`, … in attach
  order — so any reboot where AdGuard came up late gave `.3` to the edge proxy or Kuma, and AdGuard
  then died with `Address already in use`. Keep statics in `.2–.127`.
- The same network **must also pin `gateway: 172.16.25.1`**. With only an `ip_range`, Docker takes
  the bridge gateway from that range (`172.16.25.128`) — and container→edge hairpin traffic is
  SNAT'd to the gateway, so Kuma's and Homarr's requests stop matching the `172.16.25.1` entry in
  Caddy's `@lan` matcher and every LAN-only monitor has its connection aborted.
- **caddy must stay attached to `proxy_adguard`** for that to hold. Docker DNATs the published
  `:443` to caddy's endpoint on its **alphabetically first** network — `proxy_adguard` — and
  hairpin traffic from other containers is then SNAT'd to *that* network's gateway (`172.16.25.1`,
  the address `@lan` allows). If caddy ever comes up without `proxy_adguard`, the DNAT falls
  through to the next network, the source becomes that network's gateway, and Kuma's LAN-only
  checks fail again. Check with `docker inspect caddy` after recreating this network.

## First-time UI setup

> **Bootstrap (chicken-and-egg).** During first setup `https://adguard.example.com` does not
> resolve yet — that hostname only works once AdGuard itself rewrites `*.example.com` → the NAS
> IP (step 5) and Caddy proxies it. AdGuard has **no permanent host port** for its web UI (only `:53`
> DNS is published), so to reach the wizard, **temporarily** add `30004:30004` to the stack's
> `ports:`, then open `http://192.168.178.111:30004`. Remove that
> mapping once the Caddy vhost exists. See the same note in [network.md](../network.md) → DNS / reverse proxy.

After the stack is up, do this in the AdGuard web UI:

1. **Setup wizard** — with the temporary `30004:30004` mapping in place (see Bootstrap note above), first visit to `http://192.168.178.111:30004` runs the wizard. Set the **Admin Web Interface** to listen on port **30004** (not 80/3000 — Caddy's upstream is `adguard:30004`) and DNS on **port 53**. Create the admin user + password.
2. **Upstream DNS** — Settings → **DNS settings**: set upstream resolvers (e.g. `https://dns.cloudflare.com/dns-query`), enable a bootstrap/fallback, test upstreams.
3. **Blocklists** — Filters → **DNS blocklists**: add the lists you want (AdGuard default + extras).
4. **Make it the LAN resolver** — point the router/FritzBox DHCP **DNS server** at the NAS IP so every device resolves through AdGuard. (This is what makes blocking actually take effect.)
5. **Local hostnames (optional)** — Filters → **DNS rewrites** for internal names; Settings → **Clients** to label/per-client rules.

## Operations

> Restart/redeploy go through **Komodo** (Stack `adguard`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `adguard` → **Restart** (bounce) or **Deploy** (re-pull image).
- Or push to `stacks/adguard/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Pinned to a fixed `adguard/adguardhome` `tag@sha256:…` (exact version in the compose file).
  Renovate opens the bump PR and the review sweep merges it in the 05:00–06:00 window when cleared.
  AdGuard is **DNS for the whole LAN**, so read the release notes before hand-merging anything the
  review flagged `RISK: REVIEW`.

### Restore from backup

1. Stop the `adguard` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/adguard/config` (filters, DNS rewrites, clients, settings) — and optionally `apps/adguard/workdir` (stats/query log, regenerable) — from a local ZFS snapshot of `apps` (every 4h) or from Hetzner ([backup runbook](../runbooks/backup-restore/backup.md)).
3. Start the stack.

### Common failures

- **Whole LAN loses DNS** → container down or port 53 not bound. Check `NET_BIND_SERVICE` cap is set. Stop-gap: point the router's DHCP DNS at the FritzBox / `1.1.1.1` until AdGuard is back.
- **DNS works, web UI unreachable** → normal: the web UI has no host port. Reach it via Caddy (`adguard.example.com`), or add a temporary `30004:30004` mapping for direct access.
- **Resolution died right after an update** → roll back by reverting the pin and redeploying.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack.

2026-09-11
