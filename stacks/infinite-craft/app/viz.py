#!/usr/bin/env python3
"""Write the crawler DB as one self-contained, interactive graph.html (canvas + d3-force, inlined).

Embeds the --max-nodes shallowest elements (ties: most used first), so every element's best-recipe parents
come before it; the page draws the first --show of them and has a slider to change that. Docs: docs/services/infinite-craft.md
"""

import argparse
import json
import os
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path

import craftdb

HERE = Path(__file__).resolve().parent
D3_PARTS = ("d3-dispatch", "d3-quadtree", "d3-timer", "d3-force")
STARTER_EMOJI = {"Water": "💧", "Fire": "🔥", "Wind": "🌬️", "Earth": "🌍"}
MAX_RECIPES_SHOWN = 40


def build(conn, max_nodes, max_depth, show):
    rows = craftdb.recipes(conn)
    depth, best = craftdb.compute_depths(rows)
    uses = Counter()
    for a, b, _ in rows:
        uses[a] += 1
        if b != a:
            uses[b] += 1
    emoji, is_new = {}, {}
    for r, e, n in conn.execute("SELECT result, emoji, is_new FROM pair WHERE result != ?", (craftdb.NOTHING,)):
        if e and r not in emoji:
            emoji[r] = e
        is_new[r] = max(is_new.get(r, 0), n)
    for name, e in STARTER_EMOJI.items():
        emoji.setdefault(name, e)

    names = [n for n, d in depth.items() if not max_depth or d <= max_depth]
    names.sort(key=lambda n: (depth[n], -uses[n], n))
    names = names[:max_nodes]
    index = {n: i for i, n in enumerate(names)}

    edges, made_by, nrec = set(), defaultdict(list), Counter()
    for a, b, r in rows:
        if r in depth:
            nrec[r] += 1
        if r not in index:
            continue
        for p in (a, b):
            if p in index and p != r:
                edges.add((index[p], index[r]))
        if a in index and b in index:
            made_by[r].append((a, b))

    recipes = {}
    for r, lst in made_by.items():
        lst.sort(key=lambda ab: (ab != best.get(r), depth[ab[0]] + depth[ab[1]], ab))  # best recipe first
        recipes[index[r]] = [[index[a], index[b]] for a, b in lst[:MAX_RECIPES_SHOWN]]

    node_rows = []
    for n in names:
        a, b = best.get(n, (None, None))
        node_rows.append([n, emoji.get(n, ""), depth[n], uses[n], is_new.get(n, 0),
                          index.get(a, -1) if a else -1, index.get(b, -1) if b else -1])
    return {
        "meta": {"shown": len(names), "show": min(show, len(names)), "total": len(depth), "recipes": len(rows),
                 "source": craftdb.get_meta(conn, "source", "crawl"),
                 "generated": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())},
        "nodes": node_rows,
        "edges": [v for e in sorted(edges) for v in e],
        "recipes": recipes,
        "nrec": [nrec[n] for n in names],
    }


def render(data):
    tpl = (HERE / "graph_template.html").read_text(encoding="utf-8")
    d3 = "\n".join(f"<script>{(HERE / 'vendor' / (p + '.min.js')).read_text(encoding='utf-8')}</script>" for p in D3_PARTS)
    blob = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    return tpl.replace("<!--__D3__-->", d3).replace("/*__DATA__*/null", blob)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--db", default=craftdb.DEFAULT_DB, help="SQLite file (env CRAFT_DB)")
    p.add_argument("--out", default=os.environ.get("CRAFT_OUT", "/data/www/graph.html"), help="env CRAFT_OUT")
    p.add_argument("--max-nodes", type=int, default=int(os.environ.get("CRAFT_VIZ_MAX_NODES", "6000")),
                   help="most elements embedded, the slider's upper end (env CRAFT_VIZ_MAX_NODES, default 6000)")
    p.add_argument("--show", type=int, default=int(os.environ.get("CRAFT_VIZ_SHOW", "2000")),
                   help="elements drawn when the page opens (env CRAFT_VIZ_SHOW, default 2000)")
    p.add_argument("--max-depth", type=int, default=int(os.environ.get("CRAFT_VIZ_MAX_DEPTH", "0")),
                   help="hide deeper elements, 0 = no limit (env CRAFT_VIZ_MAX_DEPTH)")
    args = p.parse_args()

    conn = craftdb.connect(args.db)
    data = build(conn, args.max_nodes, args.max_depth, args.show)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=out.parent, prefix=".graph-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(render(data))
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)  # a browser never sees a half-written page
    index = out.parent / "index.html"
    if out.name != "index.html" and not index.is_symlink() and not index.exists():
        index.symlink_to(out.name)
    print(f"wrote {out} ({out.stat().st_size // 1024} KiB): {len(data['nodes'])} of {data['meta']['total']} "
          f"elements, {len(data['edges']) // 2} edges")


if __name__ == "__main__":
    main()
