"""Shared SQLite schema and depth computation for the Infinite Craft tools. Docs: docs/services/infinite-craft.md"""

import os
import sqlite3
from collections import defaultdict

STARTERS = ("Water", "Fire", "Wind", "Earth")
NOTHING = "Nothing"
DEFAULT_DB = os.environ.get("CRAFT_DB", "/data/craft.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS pair (
    a TEXT NOT NULL, b TEXT NOT NULL, result TEXT NOT NULL,
    emoji TEXT NOT NULL DEFAULT '', is_new INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (a, b)
);
CREATE INDEX IF NOT EXISTS pair_result ON pair (result);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def connect(path, threaded=False):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    conn = sqlite3.connect(path, timeout=30, check_same_thread=not threaded)
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def key(x, y):
    """Order never matters to the API; the table stores the sorted pair."""
    return (x, y) if x <= y else (y, x)


def recipes(conn):
    """Every recipe that produces an element, i.e. all but "Nothing"."""
    return conn.execute("SELECT a, b, result FROM pair WHERE result != ?", (NOTHING,)).fetchall()


def compute_depths(rows):
    """Return (depth, best): starters are 0, a result is min over recipes of max(depth(a), depth(b)) + 1.

    best[result] is the (a, b) recipe that gives that minimum; ties go to the smaller depth sum, then
    to the names, so the same DB always yields the same tree. Runs level by level: a recipe is only
    looked at when its later parent is finalised, so every recipe is visited at most twice.
    """
    by_parent = defaultdict(list)
    for a, b, r in rows:
        by_parent[a].append((a, b, r))
        if b != a:
            by_parent[b].append((a, b, r))
    depth = {s: 0 for s in STARTERS}
    best = {}
    frontier = sorted(depth)
    level = 0
    while frontier:
        cand = {}
        for x in frontier:
            for a, b, r in by_parent.get(x, ()):
                if r in depth:
                    continue
                da, db = depth.get(a), depth.get(b)
                if da is None or db is None or max(da, db) != level:
                    continue
                k = (da + db, a, b)
                if r not in cand or k < cand[r]:
                    cand[r] = k
        level += 1
        for r, (_, a, b) in cand.items():
            depth[r] = level
            best[r] = (a, b)
        frontier = sorted(cand)
    return depth, best


def get_meta(conn, name, default=None):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (name,)).fetchone()
    return row[0] if row else default


def set_meta(conn, name, value):
    conn.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                 (name, str(value)))
    conn.commit()
