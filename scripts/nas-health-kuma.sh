#!/bin/sh
# Read-only monitor definitions of both Kuma databases (NAS live, A1 nightly mirror), a fixed column
# list only: no tokens, passwords or notification configs. Docs: docs/runbooks/setup-operations/kuma-monitors.md
set -eu

NAS_DB="${KUMA_NAS_DB:-/mnt/apps/kuma/kuma.db}"
A1_DB="${KUMA_A1_DB:-/mnt/apps/a1-matrix/kuma/kuma.db}"

exec /usr/bin/python3 - "$NAS_DB" "$A1_DB" <<'PY'
import json
import os
import sqlite3
import sys

COLUMNS = (
    "id name type active parent url hostname port interval retry_interval maxretries "
    "accepted_statuscodes_json expiry_notification dns_resolve_server dns_resolve_type "
    "method keyword upside_down ignore_tls"
).split()


def read(path):
    if not os.path.exists(path):
        return {"error": f"missing {path}"}
    try:
        # mode=ro, never immutable=1: immutable skips the WAL and shows stale data.
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        db.execute("PRAGMA query_only=ON")
        rows = [dict(zip(COLUMNS, r)) for r in db.execute(
            "SELECT " + ", ".join(COLUMNS) + " FROM monitor ORDER BY id")]
        notes = {}
        for mid, name in db.execute(
                "SELECT mn.monitor_id, n.name FROM monitor_notification mn "
                "JOIN notification n ON n.id = mn.notification_id ORDER BY n.name"):
            notes.setdefault(mid, []).append(name)
        mtime = int(os.path.getmtime(path))
    except sqlite3.Error as e:
        return {"error": f"{path}: {e}"}
    names = {r["id"]: r["name"] for r in rows}
    for r in rows:
        r["notifications"] = notes.get(r["id"], [])
        r["parent"] = names.get(r["parent"], "")
        del r["id"]
    return {"mtime": mtime, "monitors": rows}


json.dump({"nas": read(sys.argv[1]), "a1": read(sys.argv[2])}, sys.stdout)
print()
PY
