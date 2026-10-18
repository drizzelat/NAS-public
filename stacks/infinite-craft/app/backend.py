#!/usr/bin/env python3
"""Own Infinite-Craft-style /pair backend: a Claude model invents each combination once, SQLite remembers it.

Same wire format as neal.fun, so `crawl.py --api-url http://<host>:8081/api/infinite-craft/pair` works
unchanged. These are NOT neal.fun's recipes. --mock answers from a hash, for tests, with no API key.
Docs: docs/services/infinite-craft.md
"""

import argparse
import hashlib
import json
import os
import re
import signal
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import craftdb

API = os.environ.get("CRAFT_BACKEND_API_URL", "https://api.anthropic.com/v1/messages")  # overridable for tests
SYSTEM = (
    "You are the combination engine of a crafting game. The player combines two elements and you "
    "answer with the single element they make. Rules: the result is a short, common noun or concept "
    "(one to three words, Title Case, no punctuation); it may be a materially sensible blend, a "
    "pun-free real-world thing, or occasionally one of the two inputs; the order of the two elements "
    "never matters. Answer \"Nothing\" only when no sensible combination exists, which should be rare. "
    "Reply with exactly one JSON object and nothing else: {\"result\": \"<name>\", \"emoji\": \"<one emoji>\"}."
)
NAME_OK = re.compile(r"^[^\n\r{}\"\\]{1,40}$")
ADJ = ("Wild Old Deep Pale Hot Cold Big Tiny Dark Bright Soft Hard Wet Dry Fast Slow").split()
NOUN = ("Stone Cloud Tree River Storm Dust Ice Salt Sand Smoke Glass Metal Seed Moss Ash Rain Wave "
        "Rock Leaf Lava Mist Coal Clay Frost Vine").split()
EMOJI = "💧 🔥 🌬️ 🌍 ☁️ 🌳 🪨 ⛈️ 🧂 🏖️ 🌫️ 🪟 🌱 ☔ 🌊 🍃 🌋 ❄️ 🧱".split()
POOL = [f"{a} {n}" for n in NOUN for a in ADJ]
lock = threading.Lock()


def mock_pair(a, b):
    h = int(hashlib.sha256(f"{a}|{b}".encode()).hexdigest(), 16)
    roll = h % 100
    if roll < 8:
        return "Nothing", ""
    if roll < 20:
        pick = a if (h >> 8) % 2 else b
        return pick, ""
    return POOL[(h >> 16) % len(POOL)], EMOJI[(h >> 40) % len(EMOJI)]


def ask_claude(a, b, model, key):
    body = json.dumps({"model": model, "max_tokens": 80, "system": SYSTEM,
                       "messages": [{"role": "user", "content": f"First: {a}\nSecond: {b}"}]}).encode()
    req = urllib.request.Request(API, body, {"x-api-key": key, "anthropic-version": "2023-06-01",
                                             "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = json.load(resp)["content"][0]["text"]
    data = json.loads(text[text.index("{"):text.rindex("}") + 1])
    result = str(data["result"]).strip()
    if not NAME_OK.match(result):
        raise ValueError(f"unusable result {result!r}")
    return result, str(data.get("emoji") or "").strip()[:8]


class Handler(BaseHTTPRequestHandler):
    conn = None
    mock = False
    model = ""
    key = ""

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 — http.server API
        url = urllib.parse.urlparse(self.path)
        if url.path == "/health":
            return self.reply(200, {"ok": True})
        q = urllib.parse.parse_qs(url.query)
        if url.path != "/api/infinite-craft/pair" or "first" not in q or "second" not in q:
            return self.reply(404, {"error": "not found"})
        a, b = craftdb.key(q["first"][0].strip(), q["second"][0].strip())
        if not (NAME_OK.match(a) and NAME_OK.match(b)):
            return self.reply(400, {"error": "bad element name"})
        with lock:
            row = self.conn.execute("SELECT result, emoji, is_new FROM pair WHERE a = ? AND b = ?", (a, b)).fetchone()
            if row is None:
                try:
                    result, emoji = mock_pair(a, b) if self.mock else ask_claude(a, b, self.model, self.key)
                except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError) as e:
                    print(f"upstream failure for {a} + {b}: {e}", flush=True)
                    return self.reply(502, {"error": "upstream failure"})
                new = int(self.conn.execute("SELECT 1 FROM pair WHERE result = ? LIMIT 1", (result,)).fetchone() is None
                          and result not in craftdb.STARTERS and result != craftdb.NOTHING)
                self.conn.execute("INSERT INTO pair (a, b, result, emoji, is_new) VALUES (?, ?, ?, ?, ?)",
                                  (a, b, result, emoji, new))
                self.conn.commit()
                row = (result, emoji, new)
        self.reply(200, {"result": row[0], "emoji": row[1], "isNew": bool(row[2])})

    def log_message(self, fmt, *args):
        print(self.address_string(), fmt % args, flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--db", default=os.environ.get("CRAFT_BACKEND_DB", "/data/backend.db"))
    p.add_argument("--port", type=int, default=int(os.environ.get("CRAFT_BACKEND_PORT", "8081")))
    p.add_argument("--bind", default="0.0.0.0")  # noqa: S104 — container-internal
    p.add_argument("--model", default=os.environ.get("CRAFT_BACKEND_MODEL", "claude-haiku-5-5"))
    p.add_argument("--mock", action="store_true", help="answer from a hash instead of the API")
    args = p.parse_args()
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not args.mock and not key:
        raise SystemExit("ANTHROPIC_API_KEY is not set (or pass --mock)")
    Handler.conn = craftdb.connect(args.db, threaded=True)
    Handler.mock, Handler.model, Handler.key = args.mock, args.model, key
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    print(f"backend on {args.bind}:{args.port} db={args.db} {'MOCK' if args.mock else args.model}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
