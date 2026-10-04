# Cloudflare zone, as recorded

A **read-only** copy of the zone, exported daily and diffed against what is committed here. This
directory is a record, not a source of truth: nothing in this repo writes to Cloudflare.

| File | Holds |
| ---- | ----- |
| `dns-records.json` | every DNS record — name, type, content, `proxied`, TTL |
| `firewall-rules.json` | the `http_request_firewall_custom` phase's rules |

Both are written by [`.github/scripts/cloudflare-export.py`](../.github/scripts/cloudflare-export.py).
Seeding them, the read-only token, and what to do when the daily run goes red:
[cloudflare-config-drift.md](../docs/runbooks/setup-operations/cloudflare-config-drift.md).
