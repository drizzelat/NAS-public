# Service: Uptime Kuma

## Overview

Uptime Kuma is a self-hosted monitoring and status-page tool. It pings services and sends alerts when something goes down.

## Stack

- **Stack folder:** `stacks/kuma/`
- **Compose file:** `stacks/kuma/docker-compose.yml`
- **Deploy:** Komodo Stack `kuma` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                          |
| ----- | ------------------------------ |
| URL   | `https://kuma.example.com`   |
| Port  | 31050                          |
| Auth  | Local admin user               |

## Volumes / data

| Container path | Host path        | Purpose          |
| -------------- | ---------------- | ---------------- |
| `/app/data`    | `/mnt/apps/kuma` | Database & config|

## Environment variables

| Variable | Description |
| -------- | ----------- |
| `TZ`     | Timezone    |
| `UPTIME_KUMA_PORT` | Port the app listens on (31050) |

## Dependencies

- AdGuard (`172.16.25.3` on `proxy_adguard`) for split-horizon DNS — see Notes.
- `proxy_kuma` (external) — defined by the `caddy` stack.

## Notes

- `NET_RAW` capability is required for ICMP (ping) monitors.
- `DAC_OVERRIDE` capability is required for the root container process to write to its volume since all other capabilities are dropped (`cap_drop: ALL`).
- Uses custom `dns: 172.16.25.3` (AdGuard Home's static IP on the `proxy_adguard` network) so internal `*.example.com` names resolve locally instead of hitting Cloudflare (avoiding 525 errors). It must be AdGuard's **container** IP, not the host LAN IP `192.168.178.111` — the latter routes DNS through Docker UDP hairpin NAT, which drops the query (`getaddrinfo EAI_AGAIN`). AdGuard's IP is pinned in `stacks/adguard/docker-compose.yml`.
- Resource limits: 0.5 CPU, 512 MB RAM.

## First-time UI setup

After the stack is up, do this in the Uptime Kuma web UI:

1. **Create admin** — first visit to `https://kuma.example.com` shows the create-admin form. Set username + password.
2. **Monitors** — add one per service: type (HTTP/TCP/Ping), URL or host, interval. Ping monitors need `NET_RAW` (already set). The list: [kuma-monitors runbook](../runbooks/setup-operations/kuma-monitors.md).
3. **Status page (optional)** — create a public/LAN status page grouping the monitors.
4. **Harden (optional)** — Settings → enable 2FA on the admin account.

> This instance watches from inside the house. The outside view is the [A1 Uptime Kuma](a1-vps-kuma.md),
> and a dead estate is caught by [healthchecks.io](../runbooks/setup-operations/external-heartbeat.md).

## Operations

> Restart/redeploy go through **Komodo** (Stack `kuma`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `kuma` → **Deploy** (or **Restart**).
- Or push to `stacks/kuma/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Pinned to a fixed `uptime-kuma` `tag@sha256:…` (exact version in the compose file; the [A1 instance](a1-vps-kuma.md) uses the same pin). Renovate opens the PR and the review sweep merges it when cleared.

### Restore from backup

1. Stop the `kuma` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/kuma` (SQLite DB — monitors, history, status pages, notification configs) from a ZFS snapshot of `apps` or from Hetzner.
3. Start the stack.

### Common failures

- **All ping monitors fail** → needs the `NET_RAW` capability for ICMP.
- **`getaddrinfo EAI_AGAIN <name>`** → Kuma can't resolve DNS. Ensure `dns:` points at AdGuard's `proxy_adguard` container IP (`172.16.25.3`), **not** the host LAN IP `192.168.178.111` — host-IP DNS goes through Docker UDP hairpin NAT and silently times out. Verify: `docker exec uptime-kuma node -e 'require("dns").resolve4("adguard.example.com",console.log)'`.
- **Container OOM / throttled** with many monitors → resource limits are 0.5 CPU / 512 MB; raise them in compose.
- **Kuma is the in-house watchdog** — if it's down you lose internal alerting. The A1 Kuma and healthchecks.io are the layers that notice.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack.

2026-09-11
