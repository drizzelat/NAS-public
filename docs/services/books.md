# Service: Books (Shelfmark)

## Overview

Shelfmark, a Calibre-compatible book library manager. Split out of the old `mediaserver` stack on
2026-08-21 ([STR-1](../architecture-review-2026-08-20.md#str-1--split-the-15-service-mediaserver-stack)).

A one-service stack is the point: it used to share a single Renovate PR, a single risk verdict and
a single rollback with fourteen unrelated containers.

## Stack

- **Stack folder:** `stacks/books/`
- **Compose file:** `stacks/books/docker-compose.yml`
- **Deploy:** Komodo Stack `books` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Service | URL | Port |
| --- | --- | --- |
| Shelfmark | `https://shelfmark.example.com` | 8084 |

LAN-only — not in the VPS SNI allowlist, and Caddy's `lan_only` snippet aborts any other client.

## Volumes / data

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/config` (shelfmark) | `/mnt/apps/mediaserver/config/shelfmark` | Shelfmark config |
| `/books` | `/mnt/data/mediaserver/data/media/books` | Book library |

> Host paths deliberately stayed under `/mnt/apps/mediaserver/` — the split regrouped *stacks*,
> not data.

## Environment variables

None — this stack takes no secrets from the vault.

## Dependencies

- `media_net` (external) — joined for consistency with the other split stacks; nothing depends on
  it today.
- `proxy_books` (external) — defined by the `caddy` stack.

## Operations

### Restart / redeploy

Komodo → Stacks → `books` → **Restart** or **Deploy**, or push to `stacks/books/` (the runner deploys it
through Komodo).

### Upgrade

Pinned `tag@sha256:digest`; Renovate proposes bumps, now in their own PR.

### Restore from backup

1. Stop the stack.
2. Restore `apps/mediaserver/config/shelfmark` from a ZFS snapshot or Hetzner.
3. The book library under `data/mediaserver` is **intentionally not backed up**.
4. Start the stack.

### Common failures

- **Library empty after a restore** → the `/books` bind (`/mnt/data/mediaserver/data/media/books`),
  not the config dataset.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack.

2026-09-11
