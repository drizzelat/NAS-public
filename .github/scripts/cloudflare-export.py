#!/usr/bin/env python3
"""Export the Cloudflare zone's DNS records and custom firewall rules, normalised.

Cloudflare is the one load-bearing config still edited in a UI: the orange/gray-cloud
split decides which names reach the NAS at all. This writes a stable, diffable copy so
drift against the committed baseline is visible. Read-only — it never writes to
Cloudflare. Docs: docs/runbooks/setup-operations/cloudflare-config-drift.md

    CLOUDFLARE_API_TOKEN=... ./cloudflare-export.py cloudflare/

Exit 0 = files written, 2 = the API could not be read.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.cloudflare.com/client/v4"
ZONE = os.environ.get("CLOUDFLARE_ZONE", "example.com")
TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "")

# Everything Cloudflare stamps on a record: identity and timestamps are not config.
DROP = {"id", "created_on", "modified_on", "modified_by", "meta", "zone_id", "zone_name",
        "proxiable", "locked", "tags", "ttl_locked", "version", "last_updated", "ref"}


def get(path, allow_404=False):
    req = urllib.request.Request(f"{API}/{path}", headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as fh:
            body = json.load(fh)
    except urllib.error.HTTPError as exc:
        if exc.code == 404 and allow_404:
            return None
        print(f"cloudflare {path}: HTTP {exc.code} {exc.read()[:200]!r}", file=sys.stderr)
        sys.exit(2)
    except OSError as exc:
        print(f"cloudflare {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    if not body.get("success"):
        print(f"cloudflare {path}: {body.get('errors')}", file=sys.stderr)
        sys.exit(2)
    return body["result"]


def strip(obj):
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in sorted(obj.items()) if k not in DROP}
    if isinstance(obj, list):
        return [strip(v) for v in obj]
    return obj


def main():
    if not TOKEN:
        print("CLOUDFLARE_API_TOKEN is not set", file=sys.stderr)
        return 2
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "cloudflare")
    out.mkdir(parents=True, exist_ok=True)

    zones = get(f"zones?name={ZONE}")
    if len(zones) != 1:
        print(f"expected exactly one zone named {ZONE}, got {len(zones)}", file=sys.stderr)
        return 2
    zid = zones[0]["id"]

    records = get(f"zones/{zid}/dns_records?per_page=500")
    # Sorted by name then type: the API's own order is not stable between calls.
    records = sorted((strip(r) for r in records), key=lambda r: (r.get("name", ""), r.get("type", "")))
    (out / "dns-records.json").write_text(json.dumps(records, indent=1, sort_keys=True) + "\n")

    # The custom WAF phase. A zone with no custom rules has no entrypoint ruleset,
    # which the API reports as 404 — an empty list, not a failure.
    entry = get(f"zones/{zid}/rulesets/phases/http_request_firewall_custom/entrypoint", allow_404=True)
    rules = strip((entry or {}).get("rules", []))
    (out / "firewall-rules.json").write_text(json.dumps(rules, indent=1, sort_keys=True) + "\n")

    print(f"wrote {len(records)} DNS record(s) and {len(rules)} custom firewall rule(s) to {out}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
