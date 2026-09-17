# Service: Homarr

## Overview

Homarr is a sleek, modern dashboard that puts all of your apps and services at your fingertips.

## Stack

- **Stack folder:** `stacks/homarr/`
- **Compose file:** `stacks/homarr/docker-compose.yml`
- **Deploy:** Komodo Stack `homarr` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                          |
| ----- | ------------------------------ |
| URL   | `https://homarr.example.com` |
| Port  | 7575                           |
| Auth  | Native (Authentik OIDC possible, not configured) |

## Volumes / data

| Container path | Host path                  | Purpose                           |
| -------------- | -------------------------- | --------------------------------- |
| `/appdata`     | `/mnt/apps/homarr/appdata` | SQLite DB + configs (whole state) |

> Homarr uses a single `/appdata` dir. Any leftover `configs`/`icons`/`data` host
> dirs are unused and can be deleted.

## Environment variables

Kept in the vault (`scripts/secrets.sh edit homarr`); `scripts/secrets.sh push homarr` writes them to the Komodo Variables `HOMARR__<KEY>` and deploys the stack through Komodo. Do not commit values.

| Variable                       | Description                                                                                                                         |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `HOMARR_SECRET_ENCRYPTION_KEY` | 64-char hex (`openssl rand -hex 32`). Encrypts stored integration credentials. **Back it up** — losing it makes them unrecoverable. |

## Notes

- Image: `ghcr.io/homarr-labs/homarr` (the maintained upstream).
- No `docker.sock` mounted by design (would re-introduce socket exposure).
- Centralizes access to all NAS applications in a single dashboard.
- **Split-horizon DNS**: without it, integration URLs resolve to Cloudflare and fail with
  **525** (the VPS SNI allowlist drops LAN-only names on the public path). Homarr's HTTP stack resolves via c-ares
  (`dns.resolve`), which **skips `/etc/hosts`** — which is why `extra_hosts` alone never
  worked and `dns:` is the load-bearing setting:
  - **`dns: [172.16.25.3]`** — AdGuard's static IP on `proxy_adguard` (same pattern
    as Kuma; bypasses Docker UDP hairpin NAT on the published `:53`). AdGuard's
    `*.example.com` rewrite returns the NAS LAN IP (`192.168.178.111`, Caddy `:443`),
    covering c-ares lookups. The stack joins `proxy_adguard` for this.
  - **The 16-entry `extra_hosts` block was removed 2026-08-21**
    ([STR-4](../architecture-review-2026-08-20.md#str-4--homarr-extra_hosts-block)). It
    duplicated AdGuard's wildcard, hardcoded the NAS IP into a repo whose premise is one
    source of truth, and went stale silently — by the time it was removed it was already
    missing `shelfmark`, `romm`, `filebrowser`, `questarr` and others. Verified inside the
    running container that those names resolve to `192.168.178.111` through getaddrinfo
    **without** any `/etc/hosts` entry, so AdGuard covers that path too.
  - **Adding a new integration now needs nothing here** — AdGuard's wildcard covers it.

  Traffic still goes through Caddy (hub-and-spoke isolation kept). Hairpin traffic is
  SNAT'd to `172.16.25.1`, which Caddy's `@lan` matcher already allows.

## First-time UI setup

After the stack is up, do this in the Homarr web UI:

1. **Onboarding** — first visit to `https://homarr.example.com` runs the setup wizard; create the **admin user**.
2. **Auth** — keep native login, or (optional) Settings → Authentication wire up OIDC/SSO via Authentik.
3. **Board** — create a board and add **app tiles** for each NAS service: name, URL, icon.
4. **Integrations (optional)** — add integrations (e.g. *arr, AdGuard) with API keys to show live status/widgets.
5. **Layout** — arrange tiles, set the default board, pick the theme. Cosmetic only — safe to rebuild anytime.

## Operations

> Restart/redeploy go through **Komodo** (Stack `homarr`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `homarr` → **Deploy** (or **Restart**).
- Or push to `stacks/homarr/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Pinned to a fixed `ghcr.io/homarr-labs/homarr` `tag@sha256:…` (exact version in the compose file). Renovate opens the PR and the review sweep merges it when cleared. v1 ships frequent releases.

### Restore from backup

1. Stop the `homarr` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/homarr/appdata` (whole state — SQLite DB + configs) from a ZFS snapshot of `apps` or from Hetzner.
3. Start the stack.

### Common failures

- **Integration credentials blank / decryption errors** → `HOMARR_SECRET_ENCRYPTION_KEY` changed or lost; restore the original key.
- **Integration shows 525 / unreachable** → hostname resolving via Cloudflare instead of locally. Check `dns: [172.16.25.3]` is present and AdGuard is up — c-ares lookups skip `/etc/hosts`, so AdGuard being down breaks every integration hostname (see Notes, and the DNS single-point-of-failure note in the architecture review). Diagnose inside the container: `node -e 'require("dns").resolve4("<host>",(e,a)=>console.log(a))'` — Cloudflare IPs mean DNS layer broken, `192.168.178.111` means look elsewhere.
- **Backend crashes with `JavaScript heap out of memory`** (UI errors, websocket drops; container stays "running" — the internal supervisor restarts node) → memory limit too low for the icon cache job (~28k icons). Limit is 1G in the compose file; don't lower it back to 512M.
- Cosmetic dashboard only — **not on any critical path**; safe to rebuild from scratch if needed.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
