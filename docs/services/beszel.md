# Service: Beszel

## Overview

Beszel is a lightweight server monitoring dashboard. The hub collects metrics from the agent running on the NAS host and displays them in a web UI.

## Stack

- **Stack folder:** `stacks/beszel/`
- **Compose file:** `stacks/beszel/docker-compose.yml`
- **Deploy:** Komodo Stack `beszel` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                          |
| ----- | ------------------------------ |
| URL   | `https://beszel.example.com` |
| Port  | 8090 (hub UI, also published on the **tailnet IP** `100.64.0.11:8090`), 45876 (agent) |
| Auth  | Local user (set up on first run)|

> **Why 8090 is published on the tailnet IP:** the hub is otherwise reachable only
> via Caddy (`proxy_beszel` network). The off-host agents ([micro VPS](micro-vps-beszel-agent.md),
> [A1](a1-vps-beszel-agent.md)) connect out to the hub's WebSocket endpoint and must reach it
> **directly** — `beszel.example.com` is LAN-only, Caddy's `@lan` matcher excludes the ingress
> VPS's tailnet IP, and the name is not in the public SNI allowlist. Bound to `100.64.0.11`
> (not `0.0.0.0`), so tailnet-only, not LAN/public. The `tailscale` stack must be up before
> `beszel` (fixed-IP bind) — after a reboot where it was not, redeploy `beszel`.

## Volumes / data

| Container path  | Host path                   | Purpose          |
| --------------- | --------------------------- | ---------------- |
| `/beszel_data`  | `/mnt/apps/beszel/hub_data` | Hub database     |
| `/mnt/data`     | `/mnt/data` (ro)            | Data pool metrics (`EXTRA_FILESYSTEMS`) |

> The agent does not mount the raw `/var/run/docker.sock` or host `/`. Docker
> metrics come from a sidecar **`beszel-socket-proxy`** (tecnativa/docker-socket-proxy,
> read-only, `POST=0`) reached over host loopback `tcp://127.0.0.1:42375` via
> `DOCKER_HOST`. A `:ro` socket bind only protects the inode — the daemon API still
> accepts writes — so the proxy is what actually enforces GET-only access.

## Environment variables

| Variable                       | Description                             |
| ------------------------------ | --------------------------------------- |
| `BESZEL_ENVIRONMENT_AGENT_KEY` | Agent connection key (vault → Komodo Variable) |
| `APP_URL`                      | Hub URL used for internal links         |

## Dependencies

- Agent runs in `host` network mode — it directly reads host metrics.
- Both Oracle hosts report to this hub via their own agents using the WebSocket
  (outbound) model — see [micro-vps-beszel-agent.md](micro-vps-beszel-agent.md) and
  [a1-vps-beszel-agent.md](a1-vps-beszel-agent.md).
- `proxy_beszel` (external) — defined by the `caddy` stack.
- The `tailscale` stack, for the tailnet-IP bind (see Access).

## Notes

- The agent uses `network_mode: host` so it can monitor the real host network interfaces and port 45876 is accessible from the hub.
- `APP_URL` should be updated to the public/LAN URL if you want correct links in notifications.

## First-time UI setup

After the stack is up, do this in the Beszel hub web UI:

1. **Create admin** — first visit to `https://beszel.example.com` shows the create-user form. Set up the admin account.
2. **Add the NAS system** — **Add System**: name, host, agent port **45876**. The hub generates a **key** — put it in the vault as `BESZEL_ENVIRONMENT_AGENT_KEY` (`scripts/secrets.sh edit beszel`), then `scripts/secrets.sh push beszel` so the agent reconnects.
3. **Confirm online** — the system should flip to *online* once the agent has the key. If not, check nothing blocks port 45876 on the host (agent runs `network_mode: host`).

4. **Set `APP_URL`** — confirm the `APP_URL` env var is the real hub URL so notification links work.
5. **Thresholds** — per system, set CPU/memory/disk/temperature alert thresholds.

## Operations

> Restart/redeploy go through **Komodo** (Stack `beszel`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `beszel` → **Deploy** (or **Restart**).
- Or push to `stacks/beszel/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Hub `beszel`, `beszel-agent`, and `beszel-socket-proxy` are all pinned to **version tags**`@sha256:…` (see [`stacks/beszel/docker-compose.yml`](../../stacks/beszel/docker-compose.yml) for exact `<tag>@sha256`) — the agent and socket-proxy moved off `latest` so Renovate tracks version bumps, not just digests.

### Restore from backup

1. Stop the `beszel` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/beszel/hub_data` (hub database — systems, users, alerts, history) from a ZFS snapshot of `apps` or from Hetzner.
3. Start the stack. The **agent is stateless** (re-reads host metrics); it only needs `BESZEL_ENVIRONMENT_AGENT_KEY` to reconnect.

### Common failures

- **Hub shows agent offline** → agent runs `network_mode: host` on port 45876; check the key matches and nothing blocks 45876 on the host.
- **Wrong links in notifications** → set `APP_URL` to the real hub URL.
- **Hub container down after a reboot, logs a bind error on `100.64.0.11:8090`** → `tailscale`
  was not up yet when `beszel` started. Redeploy `beszel`.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
