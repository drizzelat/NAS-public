#!/usr/bin/env python3
"""Import the community recipe dump (vantezzen/infinite-craft-solver) into the crawler's DB.

Format: {"items": [name, ...], "recipes": [[first, second, result], ...]} with indexes into items.
The dump has no emoji and no isNew flag, and is a 2024 snapshot. Existing rows are never overwritten.
Docs: docs/services/infinite-craft.md
"""

import argparse
import json
import sys
import urllib.request

import craftdb

DEFAULT_URL = "https://icscdn.vantezzen.io/recipes.json"


def load(src):
    if src.startswith(("http://", "https://")):
        with urllib.request.urlopen(urllib.request.Request(src, headers={"User-Agent": "nas-infinite-craft/1"}),
                                    timeout=60) as resp:
            return json.load(resp)
    with open(src, encoding="utf-8") as fh:
        return json.load(fh)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("source", nargs="?", default=DEFAULT_URL, help="file or URL, default the community dump")
    p.add_argument("--db", default=craftdb.DEFAULT_DB)
    args = p.parse_args()

    data = load(args.source)
    items, recs = data["items"], data["recipes"]
    if not isinstance(items, list) or not recs or len(recs[0]) != 3:
        sys.exit("unexpected dump format")
    conn = craftdb.connect(args.db)
    before = conn.execute("SELECT COUNT(*) FROM pair").fetchone()[0]
    conn.executemany(
        "INSERT OR IGNORE INTO pair (a, b, result, emoji, is_new) VALUES (?, ?, ?, '', 0)",
        (craftdb.key(items[a], items[b]) + (items[r],) for a, b, r in recs),
    )
    conn.commit()
    after = conn.execute("SELECT COUNT(*) FROM pair").fetchone()[0]
    craftdb.set_meta(conn, "source", "community recipe dump (2024)")
    print(f"imported {after - before} new pairs ({len(recs)} in the dump, {before} already present); "
          f"DB now has {after}")


if __name__ == "__main__":
    main()
