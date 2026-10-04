# Service: Caddy (edge reverse proxy)

## Overview

Caddy terminates TLS for every `*.example.com` hostname and proxies it to the container
behind it. The whole edge policy is one reviewable file, [`stacks/caddy/Caddyfile`](../../stacks/caddy/Caddyfile), with a
`caddy validate` required check on every pull request.

Public internet traffic reaches it from the **Oracle VPS** front door over Tailscale — see
[micro-vps-ingress.md](micro-vps-ingress.md). It replaced NPMplus in 2026-09.

## Stack

Three containers:

| Container | Role |
| --------- | ---- |
| `caddy` | the edge reverse proxy — TLS, access policy, every hostname |
| `crowdsec` | intrusion detection / IP reputation, and the LAPI this stack's bouncer queries |
| `crowdsec-socket-proxy` | a GET-only view of the Docker API, so CrowdSec can read Authentik's stdout — see [Authentik brute force](#authentik-brute-force) |

- **Stack folder:** `stacks/caddy/`
- **Compose file:** `stacks/caddy/docker-compose.yml`
- **Deploy:** Komodo Stack `caddy` on Server `nas`
  ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its
  folder deploys it through Komodo.
- **Edge policy:** `stacks/caddy/Caddyfile`
- **Image recipe:** `stacks/caddy/Dockerfile` (custom build — see [Image](#image))

## Access

| Field | Value |
| ----- | ----- |
| Admin UI | **none** — Caddy has no UI. That is the point; the whole config is the Caddyfile |
| HTTP | `80` — redirects to HTTPS |
| HTTPS | `443` — LAN/tailnet clients |
| HTTPS, PROXY protocol | `8443` — only the VPS ingress forwards here |
| TLS | one managed `*.example.com` wildcard, Let's Encrypt DNS-01 via Cloudflare |

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/etc/caddy` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/caddy` | The edge policy, from Komodo's clone on the NAS. The **directory** — see the note below |
| `/data` | `/mnt/apps/caddy/data` | Certificates, ACME account, OCSP staples |
| `/config` | `/mnt/apps/caddy/config` | Caddy's autosaved JSON config |
| `/var/log/caddy` | `/mnt/apps/caddy/logs` | Access log (JSON), read by CrowdSec and by [Vector](observability.md) |
| `/var/lib/crowdsec/data` | `/mnt/apps/crowdsec/data` | CrowdSec database |
| `/etc/crowdsec` | `/mnt/apps/crowdsec/config` | CrowdSec configuration |
| `/etc/crowdsec/acquis.d` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/caddy/crowdsec/acquis.d` | Which logs CrowdSec reads — git-managed, and it **shadows** the host copies underneath. The **directory**, for the same inode reason as `/etc/caddy` |
| `/var/run/docker.sock` (`ro`) | `/var/run/docker.sock` | `crowdsec-socket-proxy` only, never `crowdsec` itself |
| `/var/log/caddy` (`ro`) | `/mnt/apps/caddy/logs` | the access log again, this time as CrowdSec reads it |

> CrowdSec's data and config live in their own dataset, `apps/crowdsec`. They moved there from
> `apps/npm`, a leftover of the NPMplus era, on 2026-10-02.

> **A merged Caddyfile change is live as soon as `deploy-stacks` has deployed `caddy`, with no
> restart and no dropped connection.** The Caddyfile is bind-mounted out of Komodo's clone at
> `/mnt/apps/komodo/repos/nas`, which the deploy pulls. The Stack's `post_deploy`
> ([`komodo/resources.toml`](../../komodo/resources.toml)) then does two things, and either one
> failing fails the deploy:
>
> 1. **Checks the mount.** The Caddyfile inside the container must be byte-identical to the
>    clone's. A fresh clone would leave the mount on the deleted directory
>    ([komodo.md → Rules](komodo.md#config-mounts-come-from-komodos-clone)).
> 2. **Runs `caddy reload`.**
>
> The same deploy also delivers the [Authentik blueprints](authentik.md#configuration-in-git-blueprints).
>
> **The mount is the directory, `/etc/caddy`, not the file.** This is load-bearing. `git` replaces
> the Caddyfile rather than rewriting it, and a single-file bind mount is bound to the inode — so
> with the old file mount the container read the *original* file forever, and `caddy reload`
> re-read that stale copy, logged `adapted config to JSON` and exited `0` having changed nothing.
> A green no-op.
>
> To re-apply one by hand, press **Deploy** on the `caddy` Stack in Komodo. It pulls, checks the mount
> and reloads, and the update record's `Post Deploy` stage shows the reload. Then confirm:
>
> ```sh
> sudo docker exec caddy grep -c '<the name you changed>' /etc/caddy/Caddyfile   # 0 or 1, as expected
> ```
>
> `/etc/caddy` also carries this stack's `docker-compose.yml` and `Dockerfile`, because they sit in
> the same repo folder. Both are inert — the image's command names `/etc/caddy/Caddyfile`
> explicitly — and neither holds a secret; the env vars come from Komodo Variables.

## Environment variables

Set as Komodo Variables `CADDY__<KEY>` (`scripts/secrets.sh push caddy`); the plaintext lives in the gitignored `secrets/stack-env/caddy.env`
and the ciphertext in `secrets.enc/` — see the [secret-sync runbook](../runbooks/setup-operations/secret-sync.md).

| Variable | Description |
| -------- | ----------- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare DNS-edit token for the DNS-01 challenge |
| `CROWDSEC_API_KEY` | LAPI key for this bouncer — `cscli bouncers add caddy-bouncer` |

There is deliberately **no ACME contact address**. Nothing e-mails you about a
failing renewal, so certificate expiry is a Kuma check, not an assumption — *Caddy wildcard cert
(\*.example.com)*, see the [kuma-monitors runbook](../runbooks/setup-operations/kuma-monitors.md).
It notifies at 21/14/7 days remaining, all of which are past the point Caddy should have renewed,
so it fires only when renewal has already failed.

## The edge policy

### One wildcard certificate, not 25

The Caddyfile declares a single `*.example.com` site with the Cloudflare DNS challenge. Caddy
prefers an applicable managed wildcard over issuing per-subdomain certificates, so every
hostname shares that one cert — verified: a cold start attempts exactly one order, for
`*.example.com`. This is not cosmetic. Per-site certificates would publish every LAN-only
hostname into public Certificate Transparency logs.

That site block also **default-denies**: any `*.example.com` name with no block of its own gets
`abort`.

### LAN-only vs public

Five hostnames are public (`auth`, `files`, `immich`, `jellyfin`, `mealie`); every other one is
LAN-only. The
full per-host list is the access-control section of [network.md](../network.md), and
[`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml) asserts it every 6 h.

LAN-only hosts import one snippet:

```caddyfile
@lan {
	remote_ip 192.168.1.0/24 172.16.25.1 100.64.0.0/10
	not remote_ip 100.64.0.12
}
```

- `100.64.0.12` is the ingress VPS's tailnet IP, and it sits **inside** the allowed CGNAT range
  `100.64.0.0/10`. Excluding it is what keeps LAN-only admin UIs off the public internet.
- The IP lists OR, the two matchers AND, and `not` is not positional — there is no order to get
  wrong.
- `172.16.25.1` is the `proxy_adguard` gateway, which is what hairpinned internal traffic (Uptime
  Kuma's checks) looks like to the proxy. Removing it breaks those while every
  site still look fine from a browser.

A non-matching client gets `abort` — the connection is closed with no HTTP response, so a refusal
does not confirm the vhost exists. On the wire that is **curl exit 52**, see the
[probe runbook](../runbooks/setup-operations/edge-access-policy-probe.md).

### The `:8443` PROXY-protocol listener

The VPS forwards public `:443` with a PROXY v1 header so the real client IP survives the hop. Only
the `:8443` server takes it:

```caddyfile
servers :8443 {
	listener_wrappers {
		proxy_protocol {
			allow 100.64.0.12/32
			fallback_policy reject
		}
		tls
	}
}
```

- `proxy_protocol` **must precede** `tls` — it reads plaintext at the head of the connection.
- A site block that lists both `foo.example.com` and `https://foo.example.com:8443` is split
  by the adapter into one server per listen address, so `servers :8443` reaches only the public
  listener and `:443` never expects a PROXY header. Verified in the adapted JSON.
- `remote_ip` matches the immediate peer **or** the address set via PROXY protocol, so the one
  `@lan` matcher covers both listeners with no `real_ip` plumbing.
- A forged PROXY header on `:443` cannot claim a client IP: that listener has no wrapper, so the
  bytes are read as TLS and the handshake fails.

**The policy on `:8443` is client-IP-based for every name, not port-based.** Serving only the five
public names there is a stronger rule and Caddy expresses it cleanly, but it changes what the probe
asserts, so it would need its own review.

### Real client IP behind Cloudflare

The PROXY header carries the peer the **VPS** saw, and for the orange-clouded names
(`auth`/`files`/`immich`/`mealie`) that peer is a Cloudflare edge server, not the visitor. The same
`servers :8443` block therefore also carries:

```caddyfile
trusted_proxies static <the published Cloudflare v4 + v6 ranges>
client_ip_headers CF-Connecting-IP
```

- **Why it matters:** both halves of CrowdSec key on the client IP — the hub parser
  `crowdsecurity/caddy-logs` maps `caddy.request.client_ip` to `evt.Meta.source_ip`, and the
  bouncer reads Caddy's client-IP context var (`caddyhttp.ClientIPVarKey`). Without this a local
  ban lands on a Cloudflare PoP: it locks out every legitimate visitor behind that PoP while the
  attacker moves to the next edge address. The four `crowdsecurity/vpatch-env-access` alerts of
  2026-09-04 are recorded against `CLOUDFLARENET` for exactly this reason.
- **It does not touch access control.** `trusted_proxies` changes `client_ip` only; `remote_ip`
  stays the immediate peer or the PROXY address, and every `@lan` matcher is written against
  `remote_ip`. LAN/tailnet `:443` is outside the block and trusts no forwarding header at all.
- **`X-Forwarded-For` is deliberately not in `client_ip_headers`.** Naming it would also honour it
  on the direct-to-origin path, where nothing rewrites it. `CF-Connecting-IP` is overwritten by
  Cloudflare on every proxied request, so a client cannot forge it, and a non-Cloudflare peer is
  not trusted in the first place.
- **The ranges are static.** They are https://www.cloudflare.com/ips-v4 and `ips-v6`, verified
  2026-09-09. A module that fetches them at startup would let a failed fetch hold every site
  down, which is the same failure the `appsec_fail_open` decision avoids. Re-check the list when
  Cloudflare announces a change.
- `jellyfin` is gray-cloud, so its requests already arrived with the visitor's address and are
  unaffected.

### Authentik brute force

The access log cannot see a failed login. Authentik's flow executor answers **`200` whether the
password was right or wrong** — the verdict is in the JSON body — so no status-based scenario on
`caddy-logs` can tell a brute force from a busy sign-in. `auth.example.com` is orange-clouded and
its password form is reachable from anywhere, which makes it the one public name where that blind
spot matters. CrowdSec therefore reads Authentik's own events:

| Piece | Where |
| ----- | ----- |
| `firix/authentik` (parser `authentik-logs`, scenarios `authentik-bf` + `authentik-bf_user-enum`) | `COLLECTIONS=` in the compose |
| the acquisition | [`crowdsec/acquis.d/authentik.yaml`](../../stacks/caddy/crowdsec/acquis.d/authentik.yaml) |
| the Docker API it needs | `crowdsec-socket-proxy` |
| the client IP it keys on | `header_up X-Forwarded-For {client_ip}` on the `auth` vhost |

Both scenarios are `capacity: 5`, so five failures (or five distinct usernames) from one address
inside the leak window bans it, through the same bouncer as everything else.

**Authentik writes no log file**, only stdout, so this is a `source: docker` acquisition — the one
datasource here that is not a file. CrowdSec therefore needs the Docker API, and gets
`crowdsec-socket-proxy` (`tecnativa/docker-socket-proxy`, `POST=0`, `CONTAINERS`/`EVENTS`/`INFO`/`PING`/`VERSION`
only, socket mounted `ro`) on an `internal: true` network shared with nothing else — the same
pattern the NAS's other socket proxies used, and the reason `crowdsec` itself still has no
socket. `EVENTS` is not optional: it is how the datasource notices the container being replaced by
a deploy and re-attaches to the new one. Neither is `INFO`: the datasource calls `GET /info` when
CrowdSec starts, and a `403` there is a `fatal` that crash-loops `crowdsec` — which is what #547
shipped, leaving the edge without bans or AppSec for ~7 h until the deploy-state probe caught it.

**`labels: {type: authentik-server}` in the acquisition is load-bearing.** `crowdsecurity/non-syslog`
copies that type into `evt.Parsed.program`, and `firix/authentik-logs` filters on
`program in ['authentik','authentik-server']`. Rename the type and detection stops silently — no
error, no unparsed lines, just nothing.

**The `X-Forwarded-For` override is what makes any of it usable.** Authentik takes the *rightmost*
`X-Forwarded-For` entry that is outside its own trusted CIDRs (private ranges by default). On the
Cloudflare path that entry is the **edge server**, so its events name a PoP, and a ban lands on the
PoP rather than the attacker — the failure [Real client IP behind Cloudflare](#real-client-ip-behind-cloudflare)
describes, one layer further in. Measured on 2026-09-25 with a deliberate bad login sent through
Cloudflare: the event logged a `client_ip` inside Cloudflare's own `172.64.0.0/13`, not the
visitor's address. `header_up X-Forwarded-For {client_ip}` replaces the header with the address
Caddy has already recovered from `CF-Connecting-IP`; on `:443`, where nothing is a trusted proxy,
`{client_ip}` is simply the peer. That the override beats the trusted chain was checked against
`caddy:2.11.4` on the A1, with `trusted_proxies` + `client_ip_headers CF-Connecting-IP` set as they
are here: a request carrying both a `CF-Connecting-IP` and a *different* inbound `X-Forwarded-For`
reaches the upstream as the `CF-Connecting-IP` value alone, where the same request without the
override arrives as `<inbound XFF>, <peer>` — rightmost being the peer, which is what Authentik
would have picked.

Verify, after a deploy:

```sh
# the datasource is attached and lines are moving
sudo -n docker exec crowdsec cscli metrics show acquisition | grep authentik
# the parser is loaded
sudo -n docker exec crowdsec cscli parsers list | grep authentik
# a real failed login should appear as an alert within seconds of the fifth try
sudo -n docker exec crowdsec cscli alerts list --scenario firix/authentik-bf
```

A single failed login proves the pipe end to end without waiting for a bucket to fill:

```sh
sudo -n docker logs --since 2m authentik-server-1 | grep -E '"(login_failed|invalid_identifier)"'
```

`client_ip` in that line must be the visitor's address. If it is a Cloudflare one, the `header_up`
is not in effect and every ban this raises will hit a PoP.

> **`fail2ban` is not the alternative to this, and was not added.** The NAS has no public SSH, the
> TrueNAS host cannot keep installed packages across an update, and CrowdSec already holds the
> HTTP half at the edge.

> **`LePresidente/jellyfin` was considered and deliberately left out.** Its parser fires only on
> `Authentication request for "x" has been denied (IP: y)`, and the public `:8443` block already
> `403`s every Jellyfin password endpoint, so a remote attacker never reaches the code that writes
> that line — three days of logs contain none. Only a LAN or tailnet client can produce one, and
> both `crowdsecurity/whitelists` and `local/whitelist` whitelist every private and `100.64.0.0/10`
> address. It would detect nothing until those edge `403`s are removed.

### Secret-harvest paths are refused at the edge

`(scanner_deny)` answers `403` to the `.env` / `.php` / `wp-` / `phpmyadmin` / `.git/` /
`xmlrpc` / `/passwd` / `.aws` / `actuator` / `struts` path class, on every public vhost except
`files` (below). It exists because CrowdSec cannot win this one on timing.

All three [standing manual bans](../runbooks/setup-operations/crowdsec-bouncer.md#standing-manual-bans)
have the same shape: an IP nobody has seen before fires a few hundred requests at a
secret-harvest wordlist and is gone. The 2026-09-24 burst ran **13:38:50 to 13:39:06 UTC — 16
seconds**. CrowdSec's scenarios fired and banned it, exactly as designed; it had already left. A
longer ban duration only helps if the IP comes back, and none of the three ever has.

What the scanner actually collected was `200`s: AppSec's `vpatch-env-access` rules cover a lot of
that wordlist but not its long tail (`.env.bak`, `.env~`, `.env1`, `phpinfo.php`), and Immich —
like any SPA — answers every unmatched path with its 10699-byte catch-all page. Nothing leaked,
but 82 `200`s is what FAILs check 10 of the nightly health check, and clearing that meant a manual
`cscli` ban and a runbook row each time.

A `403` costs the scanner the same page it would have got, and by check 10's own rule an all-`403`
probe is a `warn`, not a FAIL. **Keep the pattern a superset of the regex that check greps the
access log for** — then everything check 10 can FAIL on is already refused here, and the two cannot
drift into disagreeing about what a scanner path is.

`\.php` is the one part check 10 does not look for, added 2026-09-25 after the live probe showed
`/phpinfo.php` and `/info.php` still answering `200`. No vhost importing the snippet is a PHP app,
and the scanners ask constantly: 91 `.php` requests over 2026-09-08..25, every one on
`immich.example.com`, 86 of them answered `200` by the SPA catch-all. They never tripped check
10 — they were simply free reconnaissance. A PHP app behind one of these names would need its own
exception before this could stay as it is.

`crowdsec` and `appsec` are `order`ed first in the global block, so they still see every one of
these requests before `respond` short-circuits it — the scenarios keep firing and the automatic
4 h bans keep landing. This replaces the manual ban, not CrowdSec.

**Before widening the pattern, measure it.** This is a blanket deny, and a false positive is a
broken page for a real user. The pattern above was checked against 2026-09-08..25 of the access
log — 803,631 requests, 474 matches for the pattern as it stands, all 474 on
`immich.example.com` and every one a scanner:

```sh
sudo python3 - <<'EOF'
import json, gzip, glob, re, collections
pat = re.compile(r"(?i)(\.env|\.php|wp-|phpmyadmin|\.git/|xmlrpc|/passwd|\.aws|actuator|struts)")
hits = collections.Counter()
for f in sorted(glob.glob("/mnt/apps/caddy/logs/access*.log.gz")) + ["/mnt/apps/caddy/logs/access.log"]:
    with (gzip.open if f.endswith(".gz") else open)(f, "rt", errors="replace") as fh:
        for line in fh:
            try: e = json.loads(line)
            except ValueError: continue
            r = e.get("request", {})
            uri = (r.get("uri") or "").split("?")[0]
            if pat.search(uri): hits[(r.get("host"), uri[:60], e.get("status"))] += 1
for k, n in hits.most_common(40): print(n, *k)
EOF
```

### Jellyfin's public edge

Jellyfin's password endpoints are blocked at the public edge only, so the web UI logs in through
Authentik while Seerr and native apps keep using local credentials on the LAN — see the
[jellyfin-authentik-sso runbook](../runbooks/setup-operations/jellyfin-authentik-sso.md). The
public edge *is* a separate site block (`https://jellyfin.example.com:8443`). `/sso/*` and
`/QuickConnect/*` stay open by not being matched.

Both Jellyfin site blocks import `hls_playlists`, the only `encode` in the Caddyfile. It gzips
responses typed as HLS playlists and nothing else. A variant playlist for jellyfin-web is about 1.4 MB
as sent and 11 KB gzipped, and the player fetches one for every quality level it moves to
([jellyfin.md → Transcoding and bitrate](jellyfin.md#transcoding-and-bitrate)). Media segments are
already compressed, and the web UI's assets were left as they were.

### Immich's public edge

Same shape, same reason. `immich.example.com` is two site blocks: LAN/tailnet `:443` proxies straight through, and the public `:8443` twin returns `403` for

```caddyfile
@pw_login path_regexp (?i)^/api/auth/(login|admin-sign-up)$
```

so the only way in from the internet is Authentik. What is deliberately **not** matched is
`/api/oauth/*` — the browser flow and the mobile app's `app.immich:///oauth-callback` flow both
ride it — and `/share/`, the anonymous album links. Immich's own `x-api-key` clients (the CLI) are
unaffected: they never touch the password endpoint.

`/api/auth/admin-sign-up` is in the block because it only refuses once an admin exists; a restore
that comes up with an empty user table would otherwise be claimable from the internet.

> An Authentik **forward-auth proxy provider** in front of Immich was considered and is not
> possible: it 302s every request, which the mobile app cannot follow, and excluding `/api/` to fix
> that excludes the entire application. Same verdict as Jellyfin above.

### Upstreams that need `tls_insecure_skip_verify`

Caddy verifies upstream certificates by default. Two upstreams serve a self-signed
cert and would `502` without `transport http { tls_insecure_skip_verify }`:
`nas` (`https://192.168.1.111:444`), and the Authentik outpost (`https://authentik-server-1:9443`).

### The TrueNAS UI needs the original `Host`

The same snippet also sets `header_up Host {host}`. Caddy sends the **upstream** address as the
`Host` header when the upstream is written as a URL, and TrueNAS's own nginx builds its
`/` → `/ui/` redirect straight from it (`rewrite ^.* $scheme://$http_host/ui/ redirect;`) — so
`https://nas.example.com/` bounced the browser to `https://192.168.1.111:444/ui/`, the raw IP
on TrueNAS's self-signed certificate, and every visit ended on a certificate warning.

The plain `lan_only` snippet is untouched — no upstream behind it redirects by
host.

### `files` is proxied straight to the app

`files.example.com` reverse-proxies to `http://files:30052` — [FileBrowser Quantum](files.md) —
with the Authentik outpost **not** in the path. It is also the one public vhost that does **not**
`import scanner_deny`: Quantum serves user-controlled paths, so a file someone uploads or shares
could legitimately be named `.env.bak` or sit under a `.git/` directory, and a blanket path deny
would `403` their own file. No match has ever been logged on this host, scanner or otherwise. Quantum runs the OIDC flow itself, and that is the
point: public share and upload links have to resolve without an Authentik session.

### Retiring a name

Delete its vhost and drop it from `LAN_ONLY_HOSTS` and [network.md](../network.md). Nothing is
needed at Cloudflare or AdGuard: both cover `*.example.com` with a wildcard.

A retired name still resolves and TLS still completes, because the wildcard certificate matches —
but no site block does, so the request is refused with no HTTP status at all (`curl` exit 92,
`%{http_code}` `000`). That is why a name listed in `LAN_ONLY_HOSTS` without a vhost fails the
probe rather than reading as a deny. The VPS SNI allowlist keeps it off the internet.

`lan_only_status` is defined with no user. It is the shape for "the name must stay listed but the
backend is gone" (a `503` placeholder), kept so it is not re-derived next time.

## Image

The official `caddy` image has neither the Cloudflare DNS provider nor a CrowdSec bouncer, so this
stack runs a custom `xcaddy` build from [`stacks/caddy/Dockerfile`](../../stacks/caddy/Dockerfile):

| Module | Why |
| ------ | --- |
| `caddy-dns/cloudflare` | DNS-01 for the wildcard — HTTP-01 cannot issue one |
| `hslatman/caddy-crowdsec-bouncer/http` | LAPI remediation |
| `hslatman/caddy-crowdsec-bouncer/appsec` | the AppSec half |

[`build-caddy-image.yml`](../../.github/workflows/build-caddy-image.yml) builds it on a
GitHub-hosted runner and pushes `ghcr.io/drizzelat/nas-caddy:<caddy-version>`, then prints the
digest to pin. Both base images, all three plugin versions and the `--replace` overrides are pinned
in the Dockerfile, and Renovate tracks every one of them ([Upgrade](#upgrade)).

Two things keep security fixes flowing into a build no upstream image carries:

- **`apk upgrade` in the final stage.** The official `caddy:<version>-alpine` base is rebuilt only
  with its Alpine base, so fixed curl, OpenSSL and c-ares packages sit in Alpine's repository while
  the image keeps the vulnerable ones. The cost: the same Dockerfile builds a different image on a
  different day, so a digest no longer identifies the Dockerfile alone.
- **`--replace` for Go modules.** Caddy and the plugins pin their dependencies in their own
  `go.mod`, and a rebuild does not move them. Each `--replace` forces a patched version of one
  (`x/crypto`, `x/net`, `x/text` and `grpc` were Trivy findings). A replace pins an exact version,
  even below what a newer Caddy requires — Renovate keeps it at the latest release, and a line can
  go once Caddy's own `go.mod` requires that version or newer.

One finding stays: Trivy flags the `crowdsecurity/crowdsec` module for the AppSec chunked/HTTP-2
body bypass (CVE-2026-44982). The bouncer compiles in only that module's API client and models, not
the vulnerable `pkg/appsec` — that code runs in the `crowdsec` container, which is past the fix.
Forcing the module is not an option: the current bouncer release no longer compiles against a
patched one. The finding clears once a bouncer release requires a patched version.

It builds from **`main` only** — a push or a dispatch from any other branch is refused. The tag is
what Renovate watches, so a branch build used to come back as an ordinary-looking digest PR: #288
was one, graded `RISK: LOW`, and the 05:00 sweep would have deployed it. For the same reason the
sweep never merges a `nas-caddy` digest bump (`MERGE_SKIP_IMAGES`). **Merge those by hand.**

**This stack is the one exception to "Renovate bumps the upstream digest".** A Caddy CVE needs a
*rebuild*, not a pull.

## Dependencies

- The 18 `proxy_*` Docker networks: `proxy_network` (CrowdSec, and the `victoriametrics` scrape)
  plus one per proxied stack. This stack **defines** them; every other stack consumes them as
  `external: true`. Adding one is [network.md](../network.md) → Adding a New Stack. They still
  carry the `npm` compose project label from before Caddy, so every `caddy` deploy logs a harmless
  `network … was not created for project "caddy"` warning.
- The [observability stack](observability.md) also reads `/mnt/apps/caddy/logs/access.log` — a
  second reader alongside CrowdSec, which is not a conflict — and puts `victoriametrics` on
  `proxy_network` to scrape `crowdsec:6060`.
- `crowdsec`, reached as `crowdsec:8080` (LAPI) and `crowdsec:7422` (AppSec) over `proxy_network`.
- **Public reachability** depends on the [VPS ingress](micro-vps-ingress.md) + Tailscale.

## Notes

- **CrowdSec parses Caddy's JSON access log with `crowdsecurity/caddy`** — see the
  [crowdsec-bouncer runbook](../runbooks/setup-operations/crowdsec-bouncer.md). Verify with
  `cscli metrics show acquisition`: "Lines parsed" must be non-zero.
- **AppSec fails open** (`appsec_fail_open`). CrowdSec stops with its own stack, and a restart must
  not take every site down with it. LAPI remediation is unaffected.
- Caddy starts even when the LAPI is unreachable (`enable_hard_fails` is off), so a CrowdSec outage
  never holds the edge down.
- **`dns_search: .` on `caddy` and `crowdsec`.** The host hands containers `search nas.example.com`,
  and that zone has a wildcard record pointing at Cloudflare. A short name Docker DNS does not know,
  such as `crowdsec` while its container is down, therefore resolved to Cloudflare, and the
  bouncer's keep-alive connection stayed there after crowdsec came back (`403 … error code: 1003`).
  A `caddy reload` does not reset it; only a restart of the container does. Without a search domain the name is NXDOMAIN until crowdsec is back.
- **Websockets need no toggle** — `reverse_proxy` upgrades natively.
- `crowdsec` and `appsec` are plugin directives with no place in Caddy's built-in handler order,
  hence `order crowdsec first` / `order appsec after crowdsec` in the global block. Without them
  the directives are only usable inside a `route`.

## Operations

> Restart/redeploy go through **Komodo** (Stack `caddy`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless
> sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `caddy` → **Deploy**, or push to `stacks/caddy/` → the runner deploys it through
  Komodo. Every Komodo deploy ends with the Stack's `post_deploy` `caddy reload`, and a failing
  reload fails the deploy. A recreate costs every site a stop timeout plus start (~20 s on the LAN).
- A Caddyfile-only change is applied by that same deploy's `post_deploy` reload — see the volumes note above.

### Upgrade

Two PRs, and only the second one moves the edge:

1. **Renovate opens `caddy image build`** — one grouped PR for everything `stacks/caddy/Dockerfile`
   pins: both `caddy` base images, the `--with` plugins and the `--replace` overrides (a regex
   manager in `renovate.json`). It changes no compose file, so `renovate-review` is green without a
   Claude pass and the morning sweep merges it. Nothing builds before the merge: a bump that no
   longer compiles fails `build-caddy-image` on `main` (GitHub failure email) and never reaches
   the edge.
2. `build-caddy-image.yml` builds on `main`, pushes and prints `image: …@sha256:…`.
3. **Renovate opens the `nas-caddy` digest bump** (or paste the pin into
   `stacks/caddy/docker-compose.yml` yourself). The sweep skips it by design. The PR shows only the
   new digest, so read `git log -p stacks/caddy/Dockerfile` for what went into it, then merge it;
   `deploy-stacks` redeploys.

To take a fix before Renovate's next run, edit the same pins by hand, merge, and continue at step 2.
Alpine fixes arrive only when the image is rebuilt ([Image](#image)), and nothing rebuilds on a
schedule: dispatch `build-caddy-image` on `main` to take them without a Dockerfile change.

`caddy validate` runs against the new image on the pull request, so a Caddyfile the new binary
cannot parse never reaches the edge.

### Validating a Caddyfile change

The Caddyfile step of the `validate` job in [`compose-validate.yml`](../../.github/workflows/compose-validate.yml)
is part of a **required check**. By hand, with the same image the stack runs:

```sh
docker run --rm -e CLOUDFLARE_API_TOKEN=$(head -c 30 /dev/urandom | base64 | tr -d '+/=' | head -c 40) \
  -e CROWDSEC_API_KEY=x -v "$PWD/stacks/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  ghcr.io/drizzelat/nas-caddy:<tag> caddy validate --config /etc/caddy/Caddyfile
```

The Cloudflare token has to *look* like one (40 chars, `[A-Za-z0-9_-]`) — the provider rejects
obvious placeholders before the config is judged valid.

### Rollback

`deploy-stacks` auto-revert **blames the last commit**, so a bad Caddyfile push reverts
the newest stack change rather than the breaking one. Prefer a manual rollback: revert the commit and let
the runner deploy it through Komodo.

### Restore from backup

1. Stop the `caddy` stack.
2. Restore `apps/caddy` from a ZFS snapshot (certificates and the ACME account live in
   `/data`). Losing it is not fatal — Caddy re-issues the wildcard over DNS-01 — but re-issuing
   counts against Let's Encrypt's duplicate-certificate rate limit.
3. Start the stack.

### Common failures

- **`502` on `nas`** → the upstream serves a self-signed certificate and its site
  block lost `tls_insecure_skip_verify`.
- **A LAN client is refused (connection closed, curl 52)** → it is not in the `@lan` matcher.
  Check the source address actually seen; hairpinned Docker traffic arrives as a bridge gateway,
  which is why `172.16.25.1` is in the list.
- **Everything on `:8443` is denied, nothing on `:443`** → the PROXY listener wrapper is missing or
  `tls` precedes `proxy_protocol`, so every client IP reads as the VPS, which the `@lan` matcher
  denies. This fails closed and loudly. The inverse — the PROXY semantics landing on `:443` —
  fails *open* and is the one to guard against.
- **A hostname fails TLS entirely (curl 35)** → no site block for that name, and the wildcard site
  answered instead. The probe reports this separately from a deny, on purpose.
- **A Caddyfile change did not take effect** → read the `caddy` Stack's last update record in Komodo. A failed `Post Deploy` is either a Caddyfile that does not adapt, in which case the old config keeps serving, or `cmp` reporting that the mounted file differs from the clone. The second means the mount is stale. Recreate the container (an edge drop of up to ~11 s) from `/mnt/apps/komodo/repos/nas/stacks/caddy`: `sudo docker compose -p caddy up -d --force-recreate caddy`. Then **Deploy** the Stack again.
- **Bouncer logs `failed to connect to LAPI … error code: 1003`** → that is a Cloudflare error, not a
  CrowdSec one: the bouncer is talking to a public IP (`docker exec caddy netstat -tn | grep :8080`).
  Check `dns_search: .` is still on the `caddy` service, then restart `caddy`; a reload is not enough.

