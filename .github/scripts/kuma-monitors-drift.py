#!/usr/bin/env python3
"""Diff kuma/monitors/*.toml against the databases: kuma-monitors-drift.py FILE.toml... < nas-health-kuma.sh output.
PASS or FAIL lines, exit 1 on any FAIL. Docs: docs/runbooks/setup-operations/kuma-monitors.md"""
import json
import sys
import time
import tomllib

HTTP = ("url", "method", "accepted_statuscodes", "ignore_tls", "expiry_notification", "keyword", "upside_down")
# Fields that define a monitor, per type. A type missing here is a FAIL, never a silent pass.
FIELDS = {
    "http": HTTP,
    "keyword": HTTP,
    "port": ("hostname", "port"),
    "ping": ("hostname",),
    "dns": ("hostname", "port", "dns_resolve_server", "dns_resolve_type"),
    "push": (),
    "group": (),
}
COMMON = ("type", "active", "parent", "notifications")
TIMING = ("interval", "retry_interval", "maxretries")
DECLARED_KEYS = {"name", *COMMON, *TIMING, *{f for fs in FIELDS.values() for f in fs}}


def declared(raw, default_notifications):
    out = {
        "name": raw["name"], "type": raw["type"], "active": raw.get("active", True),
        "parent": raw.get("parent", ""),
        "notifications": sorted(raw.get("notifications", default_notifications)),
        "interval": raw.get("interval", 60), "maxretries": raw.get("maxretries", 0),
        "url": raw.get("url", ""), "method": raw.get("method", "GET"),
        "accepted_statuscodes": raw.get("accepted_statuscodes", ["200-299"]),
        "ignore_tls": raw.get("ignore_tls", False), "expiry_notification": raw.get("expiry_notification", False),
        "keyword": raw.get("keyword", ""), "upside_down": raw.get("upside_down", False),
        "hostname": raw.get("hostname", ""), "port": raw.get("port", 53 if raw["type"] == "dns" else None),
        "dns_resolve_server": raw.get("dns_resolve_server", ""), "dns_resolve_type": raw.get("dns_resolve_type", "A"),
    }
    out["retry_interval"] = raw.get("retry_interval", out["interval"])
    return out


def live(row):
    return {
        "name": row["name"], "type": row["type"], "active": bool(row["active"]),
        "parent": row["parent"], "notifications": sorted(row["notifications"]),
        "interval": row["interval"], "retry_interval": row["retry_interval"], "maxretries": row["maxretries"],
        "url": row["url"] or "", "method": (row["method"] or "").upper(),
        "accepted_statuscodes": json.loads(row["accepted_statuscodes_json"] or "[]"),
        "ignore_tls": bool(row["ignore_tls"]), "expiry_notification": bool(row["expiry_notification"]),
        "keyword": row["keyword"] or "", "upside_down": bool(row["upside_down"]),
        "hostname": row["hostname"] or "", "port": row["port"],
        "dns_resolve_server": row["dns_resolve_server"] or "", "dns_resolve_type": row["dns_resolve_type"] or "",
    }


def compared(monitor):
    fields = list(COMMON) + list(FIELDS[monitor["type"]])
    if monitor["type"] != "group":
        fields += TIMING
    return {f: monitor[f] for f in fields}


def check(path, helper):
    """Return (pass_message, failures) for one declared file against the helper output."""
    with open(path, "rb") as f:
        spec = tomllib.load(f)
    inst = spec["instance"]
    default_notifications = spec.get("default_notifications", [])
    fails = []

    want = {}
    for raw in spec.get("monitor", []):
        extra = set(raw) - DECLARED_KEYS
        if extra:
            fails.append(f"kuma {inst}: {path}: monitor '{raw['name']}' has unknown key(s) {sorted(extra)}")
        if raw["type"] not in FIELDS:
            fails.append(f"kuma {inst}: {path}: monitor '{raw['name']}' has type '{raw['type']}', which the check does not compare")
            continue
        if raw["name"] in want:
            fails.append(f"kuma {inst}: {path}: monitor '{raw['name']}' is declared twice")
        want[raw["name"]] = declared(raw, default_notifications)
    if fails:
        return None, fails

    got_inst = helper.get(inst)
    if got_inst is None or "error" in got_inst:
        return None, [f"kuma {inst}: cannot read the database: {(got_inst or {}).get('error', 'not in helper output')}"]

    max_age = spec.get("max_age_hours")
    age_h = (time.time() - got_inst["mtime"]) / 3600
    if max_age is not None and age_h > max_age:
        fails.append(f"kuma {inst}: the database copy is {age_h:.0f} h old (limit {max_age} h); the mirror has stopped")

    have = {}
    for row in got_inst["monitors"]:
        if row["name"] in have:
            fails.append(f"kuma {inst}: two live monitors are named '{row['name']}'")
        if row["type"] not in FIELDS:
            fails.append(f"kuma {inst}: live monitor '{row['name']}' has type '{row['type']}', which the check does not compare")
            continue
        have[row["name"]] = live(row)

    for name in sorted(want.keys() - have.keys()):
        fails.append(f"kuma {inst}: '{name}' is declared in {path} but not in Kuma; add it in the UI or drop it from the file")
    for name in sorted(have.keys() - want.keys()):
        fails.append(f"kuma {inst}: '{name}' is in Kuma but not declared; add it to {path} (or delete it in the UI)")
    for name in sorted(want.keys() & have.keys()):
        if want[name]["type"] != have[name]["type"]:
            fails.append(f"kuma {inst}: '{name}' is type {have[name]['type']} in Kuma, {want[name]['type']} in {path}")
            continue
        w, h = compared(want[name]), compared(have[name])
        for field in w:
            if w[field] != h[field]:
                fails.append(f"kuma {inst}: '{name}' {field}: declared {w[field]!r}, live {h[field]!r}")

    return f"kuma {inst}: {len(have)} monitors match {path}, database copy {age_h:.0f} h old", fails


def main():
    # Anything unexpected is a FAIL line, never a bare traceback: the probe counts FAIL lines.
    try:
        helper = json.load(sys.stdin)
    except ValueError as e:
        print(f"FAIL  kuma: the helper output is not JSON ({e})")
        return 1
    fails = 0
    for path in sys.argv[1:]:
        try:
            msg, errs = check(path, helper)
        except Exception as e:  # noqa: BLE001 — a malformed TOML or row must not pass silently
            msg, errs = None, [f"kuma: {path}: {type(e).__name__}: {e}"]
        for e in errs:
            print(f"FAIL  {e}")
        fails += len(errs)
        if msg and not errs:
            print(f"PASS  {msg}")
    if not sys.argv[1:]:
        print("FAIL  kuma: no declared monitor file given")
        return 1
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
