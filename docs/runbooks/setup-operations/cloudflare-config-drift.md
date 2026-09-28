# Runbook: Cloudflare config drift

**Status: live since 2026-09-23.** Workflow, exporter, read-only token and the baseline in
`cloudflare/` all exist. The first export recorded 10 DNS records and 2 custom WAF rules
(`Geoblock`, `AI Crawl Control`), and matches what [network.md](../../network.md) and
[email-setup.md](email-setup.md) describe: apex, `www` and the wildcard orange-clouded to the
ingress VPS, `jellyfin` gray to the same host, `matrix`/`element` gray to the A1, plus the null-MX
and `-all` SPF anti-spoofing set.

## Why, and why read-only first

Cloudflare holds three things this estate depends on: the **orange/gray-cloud split** (which names
arrive from a Cloudflare edge and therefore pass the VPS's peer allowlist), the **DNS records**
themselves, and the **WAF custom rules**. All of it is edited in a UI, and
[email-setup.md](email-setup.md) added SPF/DMARC/MX records there by hand that nothing else records.

Full infrastructure-as-code (dnscontrol, Terraform) means the repo *owns* the zone: a bad apply is a
DNS outage. So this starts the other way round — **export and diff, change nothing**. If the diff
turns out to catch real drift often enough to be worth it, owning the zone is the next step. If it
never fires, nothing was risked.

## How it works

[`cloudflare-config-drift.yml`](../../../.github/workflows/cloudflare-config-drift.yml) runs daily
(best-effort schedule, plus `workflow_dispatch`), calls
[`cloudflare-export.py`](../../../.github/scripts/cloudflare-export.py) with a **read-only** token,
and diffs the result against the committed copy in `cloudflare/`:

| File | Holds |
| ---- | ----- |
| `cloudflare/dns-records.json` | every DNS record: name, type, content, `proxied`, TTL — sorted by name then type |
| `cloudflare/firewall-rules.json` | the `http_request_firewall_custom` phase's rules |

The exporter drops everything Cloudflare stamps on a record (ids, `created_on`, `modified_on`,
`meta`), so a diff is a *config* change, never a timestamp. A difference fails the run, which mails
through the usual GitHub failure path.

## Setup

### 1. The read-only API token (Cloudflare dashboard)

1. Open <https://dash.cloudflare.com/profile/api-tokens>.
2. **Create Token** → **Create Custom Token** (*Get started* at the bottom, not one of the
   templates).
3. Name: `nas-repo drift (read-only)`.
4. Permissions — add three rows, all **Read**:
   - `Zone` → `Zone` → **Read**
   - `Zone` → `DNS` → **Read**
   - `Zone` → `Zone WAF` → **Read**
5. Zone Resources: **Include** → **Specific zone** → `example.com`.
6. Optionally set a TTL. **Continue to summary** → **Create Token** → copy it (shown once).
7. Store it:

   ```sh
   gh secret set CLOUDFLARE_READ_TOKEN --repo drizzelat/NAS   # paste the token
   ```

There is no write permission on this token on purpose: the whole design is read-only.

### 2. Seed the baseline

Every run uploads its export as the `cloudflare-export` artifact, so seeding needs no local token:

```sh
gh workflow run cloudflare-config-drift.yml --repo drizzelat/NAS
gh run download "$(gh run list --repo drizzelat/NAS --workflow cloudflare-config-drift.yml --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --repo drizzelat/NAS --name cloudflare-export --dir cloudflare/
git add cloudflare/ && git commit -m 'docs: record the Cloudflare zone as it is today'
```

With the token in hand locally, `CLOUDFLARE_API_TOKEN=<token> .github/scripts/cloudflare-export.py cloudflare/`
does the same thing.

Read the diff before committing it — this is the first time the zone has been written down, and a
record nobody remembers creating is worth a look.

### 3. After an intentional change in the UI

The run goes red the next morning. Download that run's `cloudflare-export` artifact, commit it as
the new baseline in the same PR as whatever doc the change belongs in, and the run goes green
again. That commit is the change log the
zone never had.

## Gotchas

- **The token is read-only**, so nothing here can repair the zone. Fixing drift is still a UI job.
- **`per_page=500`** covers this zone with room to spare; a zone that ever outgrows it would export
  a truncated file, which reads as drift rather than as an error — check the record count in the
  run log if a diff looks suspiciously large.
- **A zone with no custom WAF rules has no entrypoint ruleset**, which the API answers with 404.
  The exporter treats that as an empty list, not a failure.
