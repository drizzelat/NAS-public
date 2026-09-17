# Service: QDirStat

> **Archived 2026-09-15.** The `qdirstat` stack was removed because it was no longer needed, instead
> of being adopted by Komodo, which could not deploy it as written
> ([komodo-migration.md F24](../runbooks/setup-operations/komodo-migration.md#f24--a-stack-whose-every-service-is-profiled-out-cannot-be-deployed-by-komodo)).
> Its Caddy vhost, the `proxy_qdirstat` network and `/mnt/apps/qdirstat` went with it. Nothing here
> describes anything running.

## Overview

QDirStat is a graphical disk usage analyzer. The containerized version provides a web UI (via KasmVNC) for browsing disk usage on the NAS — useful for finding large files eating into storage.

## Stack

- **Stack folder:** `stacks/qdirstat/`
- **Compose file:** `stacks/qdirstat/docker-compose.yml`

## Access

| Field | Value                            |
| ----- | -------------------------------- |
| URL   | `https://qdirstat.example.com` |
| Port  | 3000                             |
| Auth  | None (LAN access only)           |

## Volumes / data

| Container path | Host path    | Purpose                        |
| -------------- | ------------ | ------------------------------ |
| `/config`      | `/mnt/apps/qdirstat/config` | QDirStat config (local to stack)|
| `/data`        | `/mnt/data`  | Data pool (read-only)          |
| `/apps`        | `/mnt/apps`  | Apps pool (read-only)          |

## Environment variables

| Variable | Description              |
| -------- | ------------------------ |
| `PUID`   | Run as UID 568           |
| `PGID`   | Run as GID 568           |
| `TZ`     | Timezone                 |

## Dependencies

None.

## Notes

- Both pools are mounted read-only — QDirStat cannot delete files through this UI.
- The `/config` volume uses an absolute path (`/mnt/apps/qdirstat/config`) because relative paths in Portainer GitOps resolve to Portainer's working directory for the stack, not the repo root.
- Runs with `no-new-privileges` and no extra seccomp/capability relaxation — the KasmVNC web UI works under the default seccomp profile.

## Manual-start only

**This stack does not start with a normal deploy.** The service carries a compose
`profiles: [manual]`, so `docker compose up` skips it entirely — it is a disk-usage GUI used
maybe quarterly, and it previously ran 24/7 with `/mnt/data` and `/mnt/apps` mounted and a proxy
route open ([STR-6](../architecture-review-2026-08-20.md#str-6--qdirstat-runs-247-for-quarterly-use)).

Portainer has no UI for compose profiles, so drive it from the NAS against the **auto-pulled repo
clone** — that path is stable, unlike Portainer's per-commit checkout directory:

```sh
# start
sudo docker compose -p qdirstat \
  -f /mnt/apps/scripts/nas/stacks/qdirstat/docker-compose.yml \
  --profile manual up -d

# stop and remove when finished
sudo docker compose -p qdirstat \
  -f /mnt/apps/scripts/nas/stacks/qdirstat/docker-compose.yml \
  --profile manual down
```

`proxy_qdirstat` is defined by the `caddy` stack and outlives this container, so the Caddy vhost
stays in place — it just returns 502 while qdirstat is down. `restart: "no"` means it also does
not come back after a reboot, and the [deploy-state probe](../runbooks/setup-operations/deploy-state-probe.md)
fails if it finds it running, so stop it when you are done.

> A normal Portainer deploy of this stack will **not** remove an already-running qdirstat
> (compose only removes orphans when asked). Stop it with the `down` above.

## Operations

> Restart/redeploy go through **Portainer**, which owns the stack definition. Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection. Manual webhook fire: `curl -k -X POST https://192.168.178.111:31015/api/stacks/webhooks/<uuid>` (UUID from `scripts/portainer-migrate/read-webhooks.ps1`).

### Restart / redeploy

- A push to `stacks/qdirstat/` fires the stack webhook ([webhook runbook](../runbooks/setup-operations/portainer-webhook-deploy.md)),
  which applies the compose change but does **not** start the service — see Manual-start only.
- To use it, start and stop it with the `docker compose --profile manual` commands above.

### Upgrade

- Pinned to a **version tag**`@sha256:…` (the last pin was `2.0-ls231@sha256:b8498c5a…`) — moved off the opaque `latest` so Renovate can see and label version bumps instead of only refreshing a digest. Renovate opens the PR; the review sweep merges it in the 05:00–06:00 window when cleared.

### Restore from backup

- **Near-stateless** — only `/mnt/apps/qdirstat/config` (KasmVNC prefs) persists, and the pools are mounted **read-only**. Recovery = redeploy; nothing meaningful to restore.

### Common failures

- **Can't delete files** → both pools are mounted read-only by design (it's an analyzer, not a file manager).

## Last updated

2026-09-15 — archived: stack removed.

2026-09-11
