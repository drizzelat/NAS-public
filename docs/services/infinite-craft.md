# Service: Infinite Craft

## Overview

Collects recipe combinations of neal.fun's Infinite Craft into a SQLite DB and renders them as one
self-contained, interactive graph page (canvas + d3-force: zoom, drag, search, ancestor path on
click). LAN-only. The crawler is **off by default**; see [Data sources](#data-sources) for why.

### Containers

| Container | Role |
| --- | --- |
| craft-worker | Loop: optional crawl slice (`CRAFT_CRAWL=1`), then rebuilds `graph.html` when the DB changed |
| craft-web | `python -m http.server` over `/data/www`, read-only; the only container on `proxy_craft` |
| craft-backend | Optional own `/pair` backend (Claude-generated recipes); only starts with `COMPOSE_PROFILES=backend` |

## Stack

- **Stack folder:** `stacks/infinite-craft/` (`app/` holds the code, mounted read-only from Komodo's clone, no image build)
- **Compose file:** `stacks/infinite-craft/docker-compose.yml`
- **Deploy:** Komodo Stack `infinite-craft` on Server `nas`. `post_deploy` runs
  [`mount-matches.sh`](../../scripts/komodo/mount-matches.sh) on `/app`, as for `files`.
- **How-to (start, stop, resume, depth, regenerate):** [`stacks/infinite-craft/README.md`](../../stacks/infinite-craft/README.md)

## Access

| | |
|---|---|
| URL | `https://craft.example.com` (Caddy `lan_only`, no host port) |
| Port | 8080 inside `proxy_craft` |
| Auth | none; LAN and tailnet only. Not in the VPS SNI allowlist, so it is not public |

## Data sources

| Source | Where | Notes |
| --- | --- | --- |
| neal.fun API | `crawl.py`, default `CRAFT_API_URL` | **Blocked on 2026-10-18**: HTTP 403 with a Cloudflare managed challenge, with and without the `Referer`/`User-Agent` headers. The crawler stops on a 403 or challenge page, never retries, and leaves a `.blocked` marker next to the DB (24 h). No workaround is built in, on purpose. |
| Community dump | `import_dump.py` | [vantezzen/infinite-craft-solver](https://github.com/vantezzen/infinite-craft-solver) recipe list, a 2024 snapshot: about 205k recipes, 31.6k elements, no emoji, no `isNew`. Imported with `INSERT OR IGNORE`. |
| Own backend | `backend.py` (`craft-backend`) | Same wire format as neal.fun; each pair is answered once by a Claude model and cached in SQLite. **These are not neal.fun's recipes.** Needs `ANTHROPIC_API_KEY`. |

Keep one DB per source (`CRAFT_DB`): mixing the dump with invented recipes makes the graph meaningless.

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/data` (worker, backend; read-only in web) | `/mnt/apps/infinite-craft` | `craft.db`, `backend.db`, `www/graph.html` |
| `/app` (read-only) | `/mnt/apps/komodo/repos/nas/stacks/infinite-craft/app` | Code, from Komodo's clone (the directory, not single files) |

`apps/infinite-craft` is a leaf dataset the cloud-sync chain carries by itself. It is **not created by
the deploy**: before the first deploy create it and hand it to uid 950 (`user: 950:950` in compose):

```sh
sudo zfs create apps/infinite-craft && sudo chown 950:950 /mnt/apps/infinite-craft
```

## Environment variables

None are secrets, and none are listed in `komodo/resources.toml`: every one has a default in the compose
file. To change one, add `KEY=value` to the Stack's `environment` in `komodo/resources.toml`.

| Variable | Default | Description |
|---|---|---|
| `CRAFT_CRAWL` | `0` | `1` makes the worker crawl before each rebuild |
| `CRAFT_API_URL` | neal.fun pair endpoint | Crawl target, e.g. `http://craft-backend:8081/api/infinite-craft/pair` |
| `CRAFT_MAX_DEPTH` | `2` | Deepest result the crawl asks for |
| `CRAFT_DELAY` | `1.0` | Seconds between requests; the crawler refuses less than 1.0 for neal.fun |
| `CRAFT_BATCH` | `500` | Requests per worker slice |
| `CRAFT_INTERVAL` | `3600` | Seconds between loops when idle, blocked or failing |
| `CRAFT_VIZ_MAX_NODES` | `6000` | Elements embedded in the page, shallowest first: the upper end of the "Show" slider. Raises page size (about 1.4 MB, gzip about a third) |
| `CRAFT_VIZ_SHOW` | `2000` | Elements drawn when the page opens; the viewer changes it with the slider (kept in the URL as `#n=`) |
| `CRAFT_VIZ_MAX_DEPTH` | `0` | Hide deeper elements, `0` = no limit |
| `ANTHROPIC_API_KEY` | empty | Only for `craft-backend`; needs a vault entry and a Komodo Variable first ([secret-sync](../runbooks/setup-operations/secret-sync.md)) |
| `COMPOSE_PROFILES` | empty | `backend` starts `craft-backend` |

## Dependencies

- `proxy_craft` (external) is defined by the `caddy` stack, which must deploy first.
- `craft-web` reads what `craft-worker` writes through the shared bind mount; it waits for no network.
- Outbound HTTPS from `craft-worker` to the crawl target only while `CRAFT_CRAWL=1`; `craft-backend` to `api.anthropic.com`.

## Notes

- **Quadratic cost.** Pairs grow with the square of the elements. Depth 3 is thousands of requests, hours at
  1 request per second. `crawl.py` prints the pending estimate before every round.
- **Resumable.** One request, one commit. SIGINT/SIGTERM stop after the current request, so a container
  restart, reboot or `docker stop` loses nothing.
- **Rendering.** Layout runs in 25 ms slices (about 1 s for 3000 nodes, page responsive meanwhile) using depth rings, the
  best-recipe tree as links and collision; the 56k drawn edges are not layout links. Edges and nodes are painted once
  into an offscreen bitmap that pan and zoom only move, so interaction stays at 60 fps; Caddy gzips the 840 KiB page.
  The worker also rebuilds `graph.html` when the code under `app/` changed.
- **How many elements.** The page embeds the `CRAFT_VIZ_MAX_NODES` shallowest elements and every edge between them,
  and draws the first `CRAFT_VIZ_SHOW`; the **Show** slider in the header changes that live (the count is kept in the
  URL as `#n=`, `#select=<name>` deep-links an element and raises the count to contain it). A prefix is always a
  complete tree, so the best-recipe path of any shown element is shown. With the full dump, 6000 elements are about
  64k edges, 1.1 MB of HTML and 370 KB gzipped, and 6000 lay out in about 2 s.
- **No Kuma monitor yet.** Add `Infinite Craft` (HTTP, `https://craft.example.com`) to
  [`kuma/monitors/nas.toml`](../../kuma/monitors/nas.toml) and the live DB in the same change; the
  deploy-state probe diffs them.

## Operations

See the [stack README](../../stacks/infinite-craft/README.md). Restart or redeploy from Komodo → Stacks →
`infinite-craft`, or push to `stacks/infinite-craft/`.

### Restore from backup

Restore `apps/infinite-craft` from a ZFS snapshot or Hetzner. Only `craft.db` matters: `graph.html`
is rebuilt on the worker's first loop, and a DB from the dump is rebuilt with `import_dump.py`.

### Common failures

- **`graph.html` missing / 404** → `craft-worker` unhealthy: `docker logs craft-worker`; a `PermissionError`
  on `/data` means the dataset is not owned by 950:950.
- **Page says "No recipes yet"** → DB empty; import the dump or enable the crawl.
- **Crawl log says `BLOCKED`** → the API returned 403 or a challenge. Stop, do not retry. The marker
  `craft.db.blocked` suppresses attempts for 24 h; `--force` overrides it and should not be a reflex.
- **Deploy fails in `post_deploy`** → `/app` shows a stale clone; see
  [komodo.md → Config mounts](komodo.md#config-mounts-come-from-komodos-clone).
