# Infinite Craft crawler + graph

Recipe DB (SQLite) and a self-contained interactive `graph.html`, served LAN-only at
`https://craft.example.com`. Service doc (sources, env, backup): [docs/services/infinite-craft.md](../../docs/services/infinite-craft.md).

| File (`app/`) | Does |
| --- | --- |
| `crawl.py` | Resumable crawler, one request at a time, `--max-depth/--max-requests/--delay/--db/--api-url` |
| `import_dump.py` | Loads the community recipe dump into the same DB |
| `viz.py` | DB to `graph.html` (d3-force inlined, works offline) |
| `worker.py` | The container loop: crawl slice (if enabled), then `viz.py` |
| `backend.py` | Optional own `/pair` backend (Claude-generated, cached) |

The neal.fun API is behind a Cloudflare challenge (403) as of 2026-10-18, so the crawl is **off**
(`CRAFT_CRAWL=0`). The usual way to fill the DB today is the dump.

All commands run on the NAS as the container user, with `docker exec`. `D=craft-worker`.

## Start, stop, resume

- **Start / stop:** Komodo → Stacks → `infinite-craft` → Deploy / Stop, or `sudo docker stop|start craft-worker craft-web`.
- **Resume:** nothing to do. Every request is committed, and `docker stop`, SIGINT, SIGTERM and a reboot all
  stop after the current request; the next run continues with the pairs not yet in the DB.
- **Auto-restart** is `restart: unless-stopped`; a crawl never repeats a stored pair, and a 403 leaves a marker
  that stops further attempts for 24 h.

## Fill the DB

```sh
# Community dump (about 205k recipes, no emoji), one-off
sudo docker exec craft-worker python /app/import_dump.py
sudo docker exec craft-worker python /app/viz.py
```

## Crawl (only if an API is reachable)

Never run a manual crawl while `CRAFT_CRAWL=1`: two crawlers double the request rate.

```sh
# 10-request test, then look at the DB
sudo docker exec craft-worker python /app/crawl.py --max-requests 10 --max-depth 2
sudo docker exec craft-worker python -c "import sqlite3; c=sqlite3.connect('/data/craft.db'); print(c.execute('select * from pair').fetchall())"
```

Unattended: add `CRAFT_CRAWL=1` to the Stack `environment` in `komodo/resources.toml` and merge. Estimate before
you do: depth 2 is a few dozen requests, depth 3 thousands (hours at 1 req/s).
`crawl.py` prints requests done, pending pairs (with hours at the current delay), elements and depth every round.

## Change the depth

`CRAFT_MAX_DEPTH` (crawl, default 2) and `CRAFT_VIZ_MAX_DEPTH` / `CRAFT_VIZ_MAX_NODES` / `CRAFT_VIZ_SHOW` (page; the viewer also has a **Show** slider) in the Stack
`environment`, or `--max-depth` on a manual run. A higher depth keeps the pairs already stored and adds the rest.

## Regenerate the graph

The worker rebuilds it every `CRAFT_INTERVAL` (3600 s) when the DB changed. Now:

```sh
sudo docker exec craft-worker python /app/viz.py                      # same settings as the worker
sudo docker exec craft-worker python /app/viz.py --show 500 --max-nodes 3000   # one-off: opens with 500, slider up to 3000
```

## Own backend (not neal.fun's recipes)

Needs `ANTHROPIC_API_KEY` as a Komodo Variable. Set `COMPOSE_PROFILES=backend` and
`CRAFT_API_URL=http://craft-backend:8081/api/infinite-craft/pair`, and use a separate DB (`--db /data/own.db`) so the
two sources are not mixed. `backend.py --mock` answers from a hash with no key, for tests.

## Local use

`python3 stacks/infinite-craft/app/crawl.py --db /tmp/craft.db --api-url <url>`, `viz.py --db ... --out graph.html`:
Python 3 standard library only, no install.
