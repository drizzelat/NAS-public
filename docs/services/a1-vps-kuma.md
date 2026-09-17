# Service: A1 Uptime Kuma (external watchdog)

## Overview

Uptime Kuma acting as the **external** watchdog for the NAS: if the house loses power, the home
internet drops, or Tailscale breaks, this instance stays up and alerts.

It runs on the **Ampere A1**, deliberately *not* on the AMD micro that serves the public ingress.
Until 2026-08-21 it ran on the ingress VPS itself, which meant the one outage it most needed to
catch — that VPS dying — took the watchdog down with it
([STR-2](../architecture-review-2026-08-20.md#str-2--the-external-watchdog-is-inside-what-it-watches)).

> **Still not a complete answer.** Both Oracle instances and the NAS are operated by the same
> person on the same accounts. A watchdog you run cannot report that everything you run is down —
> only an external receiver can. See *Dead-man's switch* below.

## Stack

- **Stack folder:** `stacks/a1-vps-kuma/`
- **Compose file:** `stacks/a1-vps-kuma/docker-compose.yml`
- **Deploy:** Komodo Stack `a1-vps-kuma` on Server `a1-vps`, adopted 2026-09-15
  ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its folder deploys it
  through Komodo.

## Access

| Field | Value |
|---|---|
| URL | `http://100.64.0.13:3001` (tailnet only — not published publicly) |
| Port | 3001, bound to the A1 tailnet IP |
| Auth | Local admin user |

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/app/data` | `/opt/kuma/data` (A1 host bind) | SQLite DB, monitors, notification config |

**A host bind, not a named volume.** The old VPS instance kept its state in an anonymous named
volume with no backup path at all, so losing the instance lost every monitor and notification
setting. `/opt/kuma/data` is now mirrored to the NAS nightly by
[`a1-file-backup.sh`](../../scripts/a1-file-backup.sh) into `/mnt/apps/a1-matrix/kuma`, which the
03:00 cloud-sync chain carries offsite — see the
[a1-matrix-backup runbook](../runbooks/backup-restore/a1-matrix-backup.md).

## Environment variables

| Variable | Description |
|---|---|
| `TZ` | Timezone (`Etc/UTC`, matching the host) |

## Dependencies

- **Tailscale** — reaches the NAS and its services; also how the NAS pulls the nightly backup.

## Notes

- `NET_RAW` is required for ICMP (ping) monitors. Everything else is dropped (`cap_drop: ALL`).
- **`DAC_OVERRIDE` is no longer needed.** It existed only because Docker initialised the *named*
  volume with the image's non-root ownership; a root-owned host bind needs no such override.
- Monitors and notification settings carried over from the VPS instance with the SQLite DB, so no
  reconfiguration was needed. Monitor list: [kuma-monitors runbook](../runbooks/setup-operations/kuma-monitors.md).

### Dead-man's switch

Kuma **push** monitors here receive heartbeats from the NAS cron jobs (dumps, config email, A1
file sync), so a job that stops running at all is itself an alert.

The reverse direction — proving something here is alive when everything here is down — cannot be
answered from inside the estate. That is now covered by **healthchecks.io**: all three hosts ping
their own check every minute, and an alerter not operated here raises the alarm when they stop.
See the [external-heartbeat runbook](../runbooks/setup-operations/external-heartbeat.md).

## Operations

### Restart / redeploy

Komodo → Stacks → `a1-vps-kuma` → **Deploy**, or push to `stacks/a1-vps-kuma/` (the runner deploys it
through Komodo).

### Restore from backup

1. Stop the stack.
2. Copy `/mnt/apps/a1-matrix/kuma/` from the NAS (or from Hetzner) back to `/opt/kuma/data` on the
   A1 and `chown -R root:root` it.
3. Start the stack. Kuma reads `kuma.db` on boot; monitors and notifications come back with it.

> The nightly sync key is **read-only** (`rrsync -ro`), so this direction needs the admin key
> `secrets/ssh/ssh-a1-key.key`.

### Common failures

- **Ping monitors all fail** — `NET_RAW` was dropped; ICMP needs it.
- **Kuma starts with an empty monitor list** — the bind mount pointed at an empty dir, so Kuma
  initialised a fresh DB. Stop it, restore `/opt/kuma/data`, start again.
- **Not reachable at `100.64.0.13:3001`** — the port binds the tailnet IP only; check
  `tailscale status` on both ends.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2), last on the A1: deploys through the Komodo Stack.

2026-09-11
