# Runbook: Enable the CrowdSec bouncer

> **The live edge is Caddy since 2026-09-07, and its bouncer is a Caddy module, not this.**
> Jump to [The Caddy bouncer](#the-caddy-bouncer). The NPMplus procedure below describes the
> removed `npm` stack and is kept only for a rollback to NPMplus — see
> [caddy.md](../../services/caddy.md) → Cutover and rollback.

## Why (NPMplus)

The `npm` stack runs a **CrowdSec** container that parses NPMplus access logs and builds ban
decisions. By itself that is **detection only** — nothing enforces the decisions. Enforcement
needs the **bouncer** built into NPMplus to be turned on and pointed at the CrowdSec LAPI.

Until this is done, CrowdSec sees the attacks but every request is still served.

## One-time setup

The bouncer needs an API key that only exists at runtime (it is a secret — **do not commit it**).

1. **Register a bouncer** in the CrowdSec container and copy the API key from the output:

   ```bash
   docker exec crowdsec cscli bouncers add npmplus
   ```

   (Over SSH, `truenas_admin` has passwordless sudo, so `sudo -n docker exec crowdsec …` works.
   The Portainer console for the `crowdsec` container does the same from a UI.)

2. **Enable the bouncer** in the NPMplus config file on the `/data` volume
   (`/mnt/apps/npm/npm/data/crowdsec/crowdsec.conf`). Set:

   ```ini
   ENABLED=true
   API_KEY=<key from step 1>
   API_URL=http://crowdsec:8080
   ```

   `npm` and `crowdsec` are both on `proxy_network`, so `crowdsec:8080` (the LAPI) resolves
   container-to-container — no host port needed.

3. **Redeploy / restart** the `npm` stack in Portainer so NPMplus reloads with the bouncer active.

   > `LOGROTATE=true` is already set on the `npm` service (compose) as the documented
   > prerequisite. Only the steps above remain, and they involve a secret, so they are not in git.

## Verify

```bash
docker exec crowdsec cscli bouncers list      # npmplus should show "valid" with a recent pull
docker exec crowdsec cscli decisions list      # active bans
```

Then confirm a banned IP gets blocked at the proxy (e.g. trigger a scenario, or add a manual
decision with `cscli decisions add --ip <ip> --duration 1m` and check it is refused).

## Notes

- Exact variable names / file path can drift between NPMplus releases — cross-check the current
  NPMplus README CrowdSec section if step 2 does not match.
- The CrowdSec collections in use (`nginx-proxy-manager`, `appsec-virtual-patching`,
  `appsec-generic-rules`) are set via the `COLLECTIONS` env on the `crowdsec` service.

## The Caddy bouncer

Caddy enforces through [`hslatman/caddy-crowdsec-bouncer`](https://github.com/hslatman/caddy-crowdsec-bouncer),
compiled into the custom image — both halves, LAPI remediation (`crowdsec`) and AppSec (`appsec`).
The `crowdsec` container itself, its database and its LAPI are the same ones NPMplus used; only
the bouncer and the log parser changed.

The key is a runtime secret, `CROWDSEC_API_KEY`, the Komodo Variable `CADDY__CROWDSEC_API_KEY` on the
`caddy` Stack, held in the age vault. Register one with `cscli bouncers add caddy-bouncer`.

### The acquisition and the parser

**This is the step that silently does nothing if skipped.** `ZoeyVid/npmplus` parses NPMplus's
log format and parses **zero** lines of Caddy's JSON access log. The Caddy side is:

- `COLLECTIONS` on the `crowdsec` service is `crowdsecurity/caddy` (which brings the
  `crowdsecurity/caddy-logs` parser) plus `crowdsecurity/appsec-virtual-patching` and
  `crowdsecurity/appsec-generic-rules`. Those two were dependencies of `ZoeyVid/npmplus`, and
  `appsec-configs/local-nas.yaml` needs their `vpatch-*` and `generic-*` rules, so they are named
  explicitly rather than inherited.
- `/mnt/apps/npm/crowdsec/config/acquis.d/caddy.yaml` (a host file, not in this repo):

  ```yaml
  filenames:
    - /var/log/caddy/access.log
  labels:
    type: caddy
  ```

- `/mnt/apps/caddy/logs` is bind-mounted at `/var/log/caddy` (`ro`) so that path exists in the
  container.

`acquis.d/npm.yaml` and the `/var/log/npm` mount are **left in place on purpose**: the file is
static now, costs nothing, and a rollback to NPMplus gets its detection back with no config work.
`ZoeyVid/npmplus` likewise stays installed — removing it would take the AppSec collections with it
as dependencies.

### Verify

```bash
docker exec crowdsec cscli metrics show acquisition   # /var/log/caddy/access.log, Lines parsed non-zero
docker exec crowdsec cscli bouncers list              # caddy-bouncer valid, recent pull
docker exec crowdsec cscli parsers list | grep caddy  # crowdsecurity/caddy-logs enabled
```

**"Lines parsed" is the whole test.** Non-zero "Lines read" with zero parsed is exactly the
failure NPMplus hit with `crowdsecurity/nginx-proxy-manager` — detection running and finding
nothing, with no error anywhere.

## Tuning

Two things bite once enforcement is live. Both fixes are host files under
`/mnt/apps/npm/crowdsec/config/` (the `crowdsec` container's `/etc/crowdsec`), not in this repo.
Back up the file you touch first.

> **Put backups in `config/.config-backups/`, never beside the original.** `acquis.d/` and
> `parsers/*/` are scanned directories. A `foo.yaml.bak` is ignored today only because the glob is
> `*.yaml`. Rename it to `foo.bak.yaml`, or let an upgrade widen the glob, and CrowdSec silently
> loads a second, stale copy of the config. One such file (`acquis.d/npm.yaml.bak-20260729`,
> carrying the wrong `type: nginx-proxy-manager` label) sat there for two weeks.

### Large uploads return 403 (AppSec body-size limit)

CrowdSec AppSec defaults to `max_body_size` 10 MB with `body_size_exceeded_action: drop`, which
answered every Immich photo or video over 10 MB with `403` on `POST /api/assets`. The proxy is not
the limit: the Caddyfile sets no `request_body` size. The tell in the `crowdsec` log:

```text
request body exceeds limit 10485760 bytes, will drop request
```

The LAN whitelist does not help: it suppresses the *decision*, but AppSec inband remediation is
returned inline to the bouncer regardless.

The action is settable **only from an `on_load` hook**, hooks live inside an appsec-config, and
`appsec_config`/`appsec_configs` resolve names against **installed hub items only**
(`expandAppsecConfigEntry`). A local config can therefore never be reached by name; it has to be
loaded by path, and `appsec_config_path` takes exactly one file. Hence a local fork of the hub
config. Both files below are live, and their header comments carry the same reasoning.

`appsec-configs/local-nas.yaml`:

```yaml
name: local/appsec-nas
default_remediation: ban
inband_rules:
  - crowdsecurity/base-config
  - crowdsecurity/vpatch-*
  - crowdsecurity/generic-*
outofband_rules:
  - crowdsecurity/experimental-*
  - crowdsecurity/appsec-generic-test
on_load:
  - apply:
      - SetBodySizeExceededAction("allow")
```

`acquis.d/appsec.yaml`:

```yaml
listen_addr: 0.0.0.0:7422
appsec_config_path: /etc/crowdsec/appsec-configs/local-nas.yaml
name: appsec
source: appsec
labels:
  type: appsec
```

Restart the `crowdsec` container only (`sudo -n docker restart crowdsec`). Caddy keeps serving:
`appsec_fail_open` in the Caddyfile lets requests through while AppSec is unreachable.

> `allow` skips **body** inspection for oversized requests only; method, URI, headers and every
> rule still apply. Do **not** raise `max_body_size` instead: CrowdSec would buffer the entire
> upload in memory.

Verify with an oversized request straight at the AppSec listener, sent from the `caddy` container
so it uses the bouncer's own `CROWDSEC_API_KEY`:

```bash
sudo -n docker exec caddy sh -c 'dd if=/dev/zero of=/tmp/big.bin bs=1M count=11 2>/dev/null
  curl -s -o /dev/null -w "code=%{http_code}\n" -X POST http://crowdsec:7422/ \
    -H "X-Crowdsec-Appsec-Api-Key: $CROWDSEC_API_KEY" -H "X-Crowdsec-Appsec-Ip: 203.0.113.5" \
    -H "X-Crowdsec-Appsec-Host: immich.example.com" -H "X-Crowdsec-Appsec-Uri: /api/assets" \
    -H "X-Crowdsec-Appsec-Verb: POST" --data-binary @/tmp/big.bin; rm -f /tmp/big.bin'
sudo -n docker logs --since 1m crowdsec 2>&1 | grep 'body inspection'
```

`code=200` and `request body exceeds limit 10485760 bytes, skipping body inspection` (not
`will drop request`) means it took. The public test IP `203.0.113.5` keeps the LAN whitelist from
masking the result.

**Upstream drift.** The rule entries are wildcards, so new `vpatch-*`/`generic-*` rules still come
from the hub automatically. Only a structural change to `appsec-default` would be missed: re-diff
against `/etc/crowdsec/hub/appsec-configs/crowdsecurity/appsec-default.yaml` after a major CrowdSec
upgrade.

### The VPS ingress IP gets banned

The ingress VPS forwards `:80` **without** PROXY protocol, so every internet scanner probing
`http://` is logged under the VPS's own tailnet IP `100.64.0.12`, and one ban would take the
public HTTP→HTTPS redirect down for everyone. `parsers/s02-enrich/my-whitelist.yaml` therefore
whitelists the whole tailnet next to the private ranges:

```yaml
  cidr:
    - "192.168.0.0/16"
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "100.64.0.0/10"
```

Nothing is lost: only `:8443` takes PROXY protocol (from the VPS alone, see the Caddyfile), so real
client IPs are still seen and still bannable there.

A whitelist stops *new* alerts but does **not** clear existing decisions:

```bash
sudo -n docker exec crowdsec cscli decisions delete --ip 100.64.0.12
sudo -n docker exec crowdsec cscli explain --type caddy --log '<a line from /mnt/apps/caddy/logs/access.log>'
```

The `explain` output should end `parser success, ignored by whitelist (Local trusted LAN)`.

## Standing manual bans

Every other decision expires by itself: community-blocklist entries (`origin=CAPI`) are refreshed
or dropped upstream, and a local scenario ban runs 4 h by default. A manual `cscli` decision does
not, so each one is listed here. Check 17 of the nightly health check matches
`cs_active_decisions{origin="cscli"}` against this table and warns on a row that is missing from it.

| IP | added | duration | why |
|---|---|---|---|
| `198.51.100.40` | 2026-09-15 | `8760h` (1 y, to 2027-09-15) | BG, AS399979 `49.3 Networking LLC`. Two passes at `immich.example.com` that day: a UA-rotating crawl of the real SPA assets (02:xx UTC, 67 requests), then 282 requests in 3 s against a secret-harvest wordlist — `.env.*`, `aws_credentials`, `sendgrid_keys`, `stripe_keys`, `/.git/config`, `Jenkinsfile`. AppSec blocked 98 inline (`crowdsecurity/vpatch-env-access`) and four log scenarios banned it within 2 s, but that ban had long expired by the next morning's check. Nothing leaked: every `200` was Immich's 10699-byte SPA catch-all. |

```bash
sudo -n docker exec crowdsec cscli decisions list --origin cscli
sudo -n docker exec crowdsec cscli decisions add --ip <ip> --duration 8760h --type ban \
  --reason "manual: <what, and the date of the traffic>"
sudo -n docker exec crowdsec cscli decisions delete --ip <ip>
```

The decision lives in CrowdSec's SQLite DB under `/mnt/apps/npm/crowdsec/data`, so it survives a
container recreate; nothing in this repo re-creates it, which is why the table above is the record.
