# CrowdSec acquisition

Mounted read-only at `/etc/crowdsec/acquis.d` from the periphery's repo clone, so every
datasource is in git. `appsec.yaml` and `caddy.yaml` predate this directory and were copied
verbatim off the host on 2026-09-25; the rest of
`/etc/crowdsec` (collections, `appsec-configs/`, the local whitelist, the database) is
still host state under `/mnt/apps/npm/crowdsec/config`.

The mount **shadows** the host directory. A file removed here is a datasource removed,
even though the host copy still exists underneath.

`labels.type` is not cosmetic: `crowdsecurity/non-syslog` copies it into
`evt.Parsed.program`, which is what the per-service parsers filter on. Renaming a type
stops detection without any error.
