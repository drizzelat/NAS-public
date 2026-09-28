# Runbook: Enable the CrowdSec bouncer

CrowdSec on its own is detection only. Enforcement is the bouncer compiled into Caddy, which
queries the CrowdSec LAPI and refuses banned addresses.

## The Caddy bouncer

Caddy enforces through [`hslatman/caddy-crowdsec-bouncer`](https://github.com/hslatman/caddy-crowdsec-bouncer),
compiled into the custom image — both halves, LAPI remediation (`crowdsec`) and AppSec (`appsec`).

The key is a runtime secret, `CROWDSEC_API_KEY`, the Komodo Variable `CADDY__CROWDSEC_API_KEY` on the
`caddy` Stack, held in the age vault. Register one with `cscli bouncers add caddy-bouncer`.

### The acquisition and the parser

**A parser that matches nothing fails silently.** The pieces:

- `COLLECTIONS` on the `crowdsec` service: `crowdsecurity/caddy` (which brings the
  `crowdsecurity/caddy-logs` parser), `crowdsecurity/appsec-virtual-patching` and
  `crowdsecurity/appsec-generic-rules` (which `appsec-configs/local-nas.yaml` needs for its
  `vpatch-*` and `generic-*` rules), and `firix/authentik`
  ([caddy.md → Authentik brute force](../../services/caddy.md#authentik-brute-force)).
- Which logs it reads is git-managed in
  [`stacks/caddy/crowdsec/acquis.d/`](../../../stacks/caddy/crowdsec/acquis.d/); `caddy.yaml` points
  at `/var/log/caddy/access.log`. That mount **shadows** the host's own `acquis.d`, so a datasource
  added on the host is discarded by the next deploy.
- `/mnt/apps/caddy/logs` is bind-mounted at `/var/log/caddy` (`ro`) so that path exists in the
  container.

`ZoeyVid/npmplus` is still installed from the NPMplus era; removing it would take the AppSec
collections with it as dependencies.

### Verify

```bash
docker exec crowdsec cscli metrics show acquisition   # /var/log/caddy/access.log, Lines parsed non-zero
docker exec crowdsec cscli bouncers list              # caddy-bouncer valid, recent pull
docker exec crowdsec cscli parsers list | grep caddy  # crowdsecurity/caddy-logs enabled
```

**"Lines parsed" is the whole test.** Non-zero "Lines read" with zero parsed means detection is
running and finding nothing, with no error anywhere.

Then confirm a banned IP is refused: `cscli decisions add --ip <ip> --duration 1m`, and request
any site from it.

## Tuning

Two things bite once enforcement is live. Both fixes are host files under
`/mnt/apps/npm/crowdsec/config/` (the `crowdsec` container's `/etc/crowdsec`), not in this repo
(only `acquis.d/` is).
Back up the file you touch first.

> **Put backups in `config/.config-backups/`, never beside the original.** `acquis.d/` and
> `parsers/*/` are scanned directories. A `foo.yaml.bak` is ignored today only because the glob is
> `*.yaml`. Rename it to `foo.bak.yaml`, or let an upgrade widen the glob, and CrowdSec silently
> loads a second, stale copy of the config.

### Ban duration, and where `duration_expr` actually goes

Scenario bans escalate: **4 h, then 8 h, 12 h, …** per repeat offender, on both the `Ip` and the
`Range` profile, since 2026-09-25. Before that both were the stock flat `duration: 4h`, which is
why a scenario ban had always expired by the next morning's health check.

`duration_expr` is a **profile-level** key — a sibling of `decisions:`, not a field of the
decision. The upstream file ships it commented out at column 0, and that column 0 is *correct*;
indenting it into the list item next to `duration:` looks tidier and does not load:

```text
level=fatal msg="while loading profiles for LAPI: while decoding /etc/crowdsec/profiles.yaml:
yaml: unmarshal errors:\n  line 3: field duration_expr not found in type models.Decision"
```

`duration` stays as the fallback if the expression ever fails to evaluate. The live shape, in both
profiles:

```yaml
decisions:
 - type: ban
   duration: 4h
duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)
on_success: break
```

Apply it to **both** profiles in the file, then test before restarting — a profile that fails to
parse leaves CrowdSec with no remediation at all, and `crowdsec -t` is the only thing standing
between a one-column mistake and that outcome:

```sh
sudo install -d -m 755 /mnt/apps/npm/crowdsec/config/.config-backups
sudo cp -a /mnt/apps/npm/crowdsec/config/profiles.yaml \
  /mnt/apps/npm/crowdsec/config/.config-backups/profiles.yaml.bak-$(date +%Y%m%d)
sudo -e /mnt/apps/npm/crowdsec/config/profiles.yaml     # make both edits
sudo docker exec crowdsec crowdsec -t                   # parse check, no restart
sudo docker restart crowdsec                            # profiles load at startup only
sudo docker logs --since 1m crowdsec 2>&1 | grep -iE 'level=(error|fatal)'
sudo docker exec crowdsec cscli decisions list          # remediation still works
sudo docker exec crowdsec cscli bouncers list           # Last API pull is after the restart
```

Read `crowdsec -t`'s **last line** — `Configuration test done` is the pass. Do not judge it by
`$?` through a pipe (`crowdsec -t | tail`): `$?` is then the pipe's status, which is `0` even
when the test printed `level=fatal`. Redirect to a file, or read the output.

Caddy is unaffected by the restart: the global block sets `appsec_fail_open`, so the sites stay up
while CrowdSec is down.

**What it does and does not buy.** It only helps an IP that comes back. None of the three in
[Standing manual bans](#standing-manual-bans) ever did — each was a single burst, the 2026-09-24
one just 16 seconds end to end, which is why the edge-level
[`(scanner_deny)`](../../services/caddy.md#secret-harvest-paths-are-refused-at-the-edge) and not a
ban policy is what removed that class of work. Treat this as the cheap second layer, not the fix.

Like everything else in this section, `profiles.yaml` is a host file outside the repo, so nothing
in CI can notice it reverting. The backup of the pre-2026-09-25 stock file is at
`.config-backups/profiles.yaml.bak-2026-09-25`.

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
or dropped upstream, and a local scenario ban runs 4 h by default.

**There should not be a fourth row.** All three below were added because a scanner collected
`200`s from Immich's SPA catch-all and FAILed check 10, not because CrowdSec missed it — it banned
every one of them within seconds, by which time a 16-second burst was already over. Since
2026-09-25 the edge answers that path class `403` itself
([`(scanner_deny)`](../../services/caddy.md#secret-harvest-paths-are-refused-at-the-edge)), which
makes the same probe a `warn` instead of a FAIL and leaves nothing to ban by hand. A new row here
means the scanner found a path the pattern does not cover — widen the pattern rather than add the
row, and measure it against the access log first. A manual `cscli` decision does
not, so each one is listed here. Check 17 of the nightly health check matches
`cs_active_decisions{origin="cscli"}` against this table and warns on a row that is missing from it.

| IP | added | duration | why |
|---|---|---|---|
| `198.51.100.40` | 2026-09-15 | `8760h` (1 y, to 2027-09-15) | BG, AS399979 `49.3 Networking LLC`. Two passes at `immich.example.com` that day: a UA-rotating crawl of the real SPA assets (02:xx UTC, 67 requests), then 282 requests in 3 s against a secret-harvest wordlist — `.env.*`, `aws_credentials`, `sendgrid_keys`, `stripe_keys`, `/.git/config`, `Jenkinsfile`. AppSec blocked 98 inline (`crowdsecurity/vpatch-env-access`) and four log scenarios banned it within 2 s, but that ban had long expired by the next morning's check. Nothing leaked: every `200` was Immich's 10699-byte SPA catch-all. |
| `198.51.100.60` | 2026-09-25 | `8760h` (1 y, to 2027-09-25) | DE, `Google LLC`. One pass at `immich.example.com` on 2026-09-24, 13:38:50–13:39:06 UTC: 260 requests in 16 s, the same secret-harvest wordlist as the two rows above (`.env.*` in every spelling, `phpinfo.php`, `info.php`). AppSec `vpatch-env-access` blocked 176 inline; the rest reached Immich, which answers everything with its SPA catch-all, so 82 got a `200`. The log scenarios (`http-sensitive-files` 38, `http-probing` 16) fired, but the burst was over before any ban could matter and the 4 h decision had expired by the morning check, which FAILed check 10 on those 82 `200`s. Nothing leaked: every one is the 10699-byte SPA page. |
| `198.51.100.50` | 2026-09-21 | `8760h` (1 y, to 2027-09-21) | DE, `Feo Prest SRL`. One pass at `immich.example.com` on 2026-09-19, 16:25:45–16:26:27 UTC: 268 requests, one UA, fetching the SPA assets and then a secret-harvest wordlist (`.env.*`, `.aws/config`, `.git-credentials`, `.kube/config`, `actuator/env`, `phpinfo.php`). `http-sensitive-files` fired 3× and AppSec `vpatch-env-access` blocked 8, so the last 168 requests got `403`. The ban had expired by the next check, which FAILed check 16 on its 16 scanner-path `200`s. Nothing leaked: every secret path got Immich's 10699-byte SPA catch-all, and the other `200`s were `/_app/immutable/*` assets. |

```bash
sudo -n docker exec crowdsec cscli decisions list --origin cscli
sudo -n docker exec crowdsec cscli decisions add --ip <ip> --duration 8760h --type ban \
  --reason "manual: <what, and the date of the traffic>"
sudo -n docker exec crowdsec cscli decisions delete --ip <ip>
```

The decision lives in CrowdSec's SQLite DB under `/mnt/apps/npm/crowdsec/data`, so it survives a
container recreate; nothing in this repo re-creates it, which is why the table above is the record.
