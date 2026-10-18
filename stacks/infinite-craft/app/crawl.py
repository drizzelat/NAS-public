#!/usr/bin/env python3
"""Resumable Infinite Craft recipe crawler: one request at a time, one DB commit per request.

Exit codes: 0 done or budget reached, 1 usage error, 2 too many consecutive failures,
3 blocked (HTTP 403 or a challenge page; no retry, see --force). Docs: docs/services/infinite-craft.md
"""

import argparse
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from itertools import islice

import craftdb

DEFAULT_API = "https://neal.fun/api/infinite-craft/pair"
HEADERS = {
    "Referer": "https://neal.fun/infinite-craft/",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0",
    "Accept": "application/json",
}
BLOCK_COOLDOWN = 24 * 3600
stop = threading.Event()


class Blocked(Exception):
    pass


class Transient(Exception):
    def __init__(self, msg, retry_after=None):
        super().__init__(msg)
        self.retry_after = retry_after


def env_num(name, default, cast):
    try:
        return cast(os.environ[name])
    except (KeyError, ValueError):
        return default


def fetch(api_url, a, b, timeout=15):
    """One pair lookup. Returns (result, emoji, is_new); raises Blocked or Transient."""
    url = f"{api_url}?{urllib.parse.urlencode({'first': a, 'second': b})}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=timeout) as resp:
            body = resp.read(1 << 20)
    except urllib.error.HTTPError as e:
        if e.code == 403:
            raise Blocked("HTTP 403") from e
        retry = e.headers.get("Retry-After") if e.headers else None
        raise Transient(f"HTTP {e.code}", int(retry) if retry and retry.isdigit() else None) from e
    except (urllib.error.URLError, OSError) as e:
        raise Transient(f"network: {e}") from e
    try:
        data = json.loads(body)
        result = data["result"]
        if not isinstance(result, str) or not result:
            raise ValueError("empty result")
    except (ValueError, KeyError, TypeError) as e:
        if b"Just a moment" in body[:4096]:
            raise Blocked("challenge page") from e
        raise Transient(f"bad response: {body[:80]!r}") from e
    return result, str(data.get("emoji") or ""), int(bool(data.get("isNew")))


def pending_pairs(depth, done, max_depth):
    """Lazily yield untried (a, b, max depth, depth sum) over elements with depth <= max_depth - 1.

    Ordered by (max depth, sum of depths): level L pairs an L-element with every element of depth
    k <= L, k ascending. Self-pairs are included; a pair is (a, b) with a <= b.
    """
    levels = {}
    for name, d in depth.items():
        if d <= max_depth - 1:
            levels.setdefault(d, []).append(name)
    for names in levels.values():
        names.sort()
    for top in sorted(levels):
        for low in range(top + 1):
            for i, x in enumerate(levels[top]):
                for y in (levels[top][i:] if low == top else levels.get(low, ())):
                    k = craftdb.key(x, y)
                    if k not in done:
                        yield k[0], k[1], top, top + low


def count_pending(depth, done, max_depth):
    names = {n for n, d in depth.items() if d <= max_depth - 1}
    total = len(names) * (len(names) + 1) // 2
    return total - sum(1 for a, b in done if a in names and b in names)


def block_file(db_path):
    return db_path + ".blocked"


def blocked_since(db_path):
    try:
        return float(open(block_file(db_path)).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def sleep(seconds):
    """Interruptible sleep: returns True when a stop was requested."""
    return stop.wait(seconds)


def run(args):
    api_host = urllib.parse.urlparse(args.api_url).hostname or ""
    delay = args.delay
    if api_host.endswith("neal.fun") and delay < 1.0:
        print("delay below 1.0s is not allowed for neal.fun; using 1.0", flush=True)
        delay = 1.0

    since = blocked_since(args.db)
    if since and not args.force and time.time() - since < BLOCK_COOLDOWN:
        left = (BLOCK_COOLDOWN - (time.time() - since)) / 3600
        print(f"blocked marker {block_file(args.db)} is {left:.1f}h from expiring; not asking again "
              f"(--force overrides)", flush=True)
        return 3

    conn = craftdb.connect(args.db)
    label = f"crawl {api_host or args.api_url}"
    known = craftdb.get_meta(conn, "source")
    if known is None:
        craftdb.set_meta(conn, "source", label)
    elif label not in known:
        craftdb.set_meta(conn, "source", f"{known} + {label}")
    done = {(a, b) for a, b in conn.execute("SELECT a, b FROM pair")}
    requests = failures = round_no = 0
    exhausted = False

    while not stop.is_set() and not exhausted:
        depth, _ = craftdb.compute_depths(craftdb.recipes(conn))
        pending = count_pending(depth, done, args.max_depth)
        reachable = sum(1 for d in depth.values() if d <= args.max_depth - 1)
        print(f"round {round_no}: {len(depth)} elements ({reachable} expandable at depth<={args.max_depth - 1}), "
              f"~{pending} pending pairs (~{pending * delay / 3600:.1f}h at {delay:g}s/req), "
              f"{requests} requests so far", flush=True)
        batch = list(islice(pending_pairs(depth, done, args.max_depth), args.round_size))
        if not batch:
            print("no pending pairs: done", flush=True)
            break
        round_no += 1
        for a, b, top, total in batch:
            if stop.is_set() or (args.max_requests and requests >= args.max_requests):
                exhausted = True
                break
            while not stop.is_set():
                try:
                    result, emoji, is_new = fetch(args.api_url, a, b)
                except Blocked as e:
                    open(block_file(args.db), "w").write(f"{time.time()} {e}\n")
                    print(f"BLOCKED ({e}) at {a} + {b}. Stopping, no retry; marker {block_file(args.db)}.",
                          flush=True)
                    return 3
                except Transient as e:
                    failures += 1
                    if failures >= args.max_failures:
                        print(f"aborting after {failures} consecutive failures (last: {e})", flush=True)
                        return 2
                    wait = e.retry_after or min(300, 2 ** failures)
                    print(f"{e}; failure {failures}/{args.max_failures}, waiting {wait}s", flush=True)
                    if sleep(wait):
                        break
                    continue
                failures = 0
                if os.path.exists(block_file(args.db)):
                    os.remove(block_file(args.db))
                conn.execute("INSERT OR IGNORE INTO pair (a, b, result, emoji, is_new) VALUES (?, ?, ?, ?, ?)",
                             (a, b, result, emoji, is_new))
                conn.commit()
                done.add((a, b))
                requests += 1
                print(f"[{requests}] parents<={top} {a} + {b} = {emoji} {result}{' (new)' if is_new else ''}",
                      flush=True)
                break
            if sleep(delay):
                break
    conn.close()
    print(f"stopped after {requests} requests; resume by running again", flush=True)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--db", default=craftdb.DEFAULT_DB, help="SQLite file (env CRAFT_DB)")
    p.add_argument("--max-depth", type=int, default=env_num("CRAFT_MAX_DEPTH", 2, int),
                   help="deepest result to crawl for (env CRAFT_MAX_DEPTH, default 2)")
    p.add_argument("--max-requests", type=int, default=0, help="request budget for this run, 0 = unlimited")
    p.add_argument("--delay", type=float, default=env_num("CRAFT_DELAY", 1.0, float),
                   help="seconds between requests (env CRAFT_DELAY, default 1.0, min 1.0 for neal.fun)")
    p.add_argument("--api-url", default=os.environ.get("CRAFT_API_URL", DEFAULT_API),
                   help="pair endpoint (env CRAFT_API_URL), e.g. the own backend")
    p.add_argument("--max-failures", type=int, default=10, help="abort after N consecutive failures")
    p.add_argument("--round-size", type=int, default=500, help="pairs per round before depths are recomputed")
    p.add_argument("--force", action="store_true", help="ignore the 24h marker left by a block")
    args = p.parse_args()
    if args.max_depth < 1 or args.delay < 0:
        p.error("--max-depth must be >= 1 and --delay >= 0")
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    sys.exit(run(args))


if __name__ == "__main__":
    main()
