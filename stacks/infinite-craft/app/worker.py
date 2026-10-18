#!/usr/bin/env python3
"""Unattended loop: crawl one budgeted slice (only when CRAFT_CRAWL=1), regenerate graph.html, sleep.

A restart at any point is safe: crawl.py commits per request and viz.py replaces the page atomically.
Env (all optional): CRAFT_CRAWL, CRAFT_BATCH, CRAFT_INTERVAL, plus the crawl.py and viz.py ones.
Docs: docs/services/infinite-craft.md
"""

import os
import signal
import subprocess
import sys
import threading

import craftdb

HERE = os.path.dirname(os.path.abspath(__file__))
stop = threading.Event()
child = None


def run(script, *args):
    global child
    child = subprocess.Popen([sys.executable, os.path.join(HERE, script), *args])
    code = child.wait()
    child = None
    return code


def code_stamp():
    """Newest mtime under app/: a changed template or viz.py rebuilds the page even when the DB did not change."""
    return max(os.stat(os.path.join(d, f)).st_mtime_ns for d, _, fs in os.walk(HERE) for f in fs)


def on_signal(signum, _frame):
    stop.set()
    if child is not None:
        child.send_signal(signum)  # crawl.py finishes its current request, then exits


def main():
    crawl = os.environ.get("CRAFT_CRAWL", "0") == "1"
    batch = os.environ.get("CRAFT_BATCH", "500")
    interval = int(os.environ.get("CRAFT_INTERVAL", "3600"))
    db = os.environ.get("CRAFT_DB", craftdb.DEFAULT_DB)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, on_signal)
    print(f"worker: crawl={'on' if crawl else 'off'} batch={batch} interval={interval}s db={db}", flush=True)

    last = None
    while not stop.is_set():
        code = None
        if crawl:
            code = run("crawl.py", "--max-requests", batch)
            print(f"worker: crawl.py exited {code}", flush=True)
        try:
            stamp = (os.stat(db).st_mtime_ns, code_stamp())
        except OSError:
            stamp = None
        out = os.environ.get("CRAFT_OUT", "/data/www/graph.html")
        changed = stamp != last
        if not stop.is_set() and (changed or not os.path.exists(out)):
            if run("viz.py") == 0:
                last = stamp
        # A slice that added rows means more work is waiting; done, blocked or failing waits a full interval.
        stop.wait(60 if code == 0 and changed else interval)
    print("worker: stopped", flush=True)


if __name__ == "__main__":
    main()
