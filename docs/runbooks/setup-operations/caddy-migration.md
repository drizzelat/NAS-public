# Plan: NPMplus → Caddy (SVC-1 / Part 8 step 6)

**Status: done 2026-09-07. Caddy serves the edge and NPMplus is gone.** Phases 0 and 1 ran
2026-09-06, phases 2 and 3 the next day; the four open questions in §10 were settled before any of
it. **The two-week soak was skipped by decision** — see §13. What was verified at each phase, and
the fourteen places this plan was wrong, are in [§11](#11-execution-record),
[§12](#12-phase-2-execution-record--2026-09-07) and
[§13](#13-phase-3-execution-record--2026-09-07).

Finding: [SVC-1](../../architecture-review-2026-08-20.md#svc-1--npmplus--caddy). Closes the
second half of [GAP-1](../../architecture-review-2026-08-20.md#gap-1--npm-and-authentik-config-is-click-ops)
(Authentik blueprints closed the first half on 2026-09-06).

## 1. The acceptance test, and its state today

[`edge-access-policy.yml`](../../../.github/workflows/edge-access-policy.yml) is the acceptance
test. It is **green against NPMplus right now** — last run `34036663368`, `success`,
2026-09-06T13:37Z, and the eight runs before it, both jobs.

What it actually asserts, read from the workflow rather than from its description:

| Job | Case | Assertion |
| --- | --- | --- |
| `sni-allowlist` | 21 LAN-only names, `curl --resolve` at the VPS public IP | connection closed before TLS: **curl exit 35** |
| `sni-allowlist` | 5 public names, same path | `200`/`3xx` |
| `sni-allowlist` | all 26 names, DoH `A` lookup | Cloudflare address, except `jellyfin` (grey-cloud) |
| `npm-access-list` | 21 LAN-only names on `:8443`, claimed client `100.64.0.12` | **deny** — `rc=56` *or* `code=403` |
| `npm-access-list` | `portainer` on `:8443`, claimed `100.64.0.1` | **allow** — `200`/`3xx` |
| `npm-access-list` | `portainer` on `:8443`, claimed `192.168.178.50` | **allow** |
| `npm-access-list` | `portainer` on `:8443`, claimed `203.0.113.10` | **deny** |
| `npm-access-list` | 5 public names on `:8443`, claimed `203.0.113.10` | **allow** |
| `npm-access-list` | — | the VPS probe's `sha256` equals `scripts/edge-access-probe.sh` |

Two consequences the Caddyfile is *constrained* by, not free to redesign around:

- **Every one of the 26 names must still answer on `:8443`.** Layer 2's deny cases are read as
  `rc=56`/`403`; a name with no vhost fails TLS instead (`rc=35`) and the probe treats that as a
  failure, correctly. So `npm` and `goaccess` — the two names that lose their backend when
  NPMplus goes — must keep a live vhost through the cutover. See §6.
- **`:8443` policy must stay client-IP-based for all 26 names, not port-based.** The tempting
  simplification is "`:8443` is the public listener, therefore serve only the 5 public names
  there". That is a stronger invariant and it is *wrong to adopt during this migration*: it
  turns the `portainer` + claimed `100.64.0.1` and `192.168.178.50` cases from allow into deny,
  and the probe goes red. Those two cases test a path no real client uses (real tailnet admins
  hit `:443` directly) — they exist because NPM shares one vhost across both ports, and they are
  how the probe proves the deny is *specific* rather than a blanket block. Mirror the semantics;
  do not improve them here. §9 records the port-based model as a deliberate follow-up.

## 2. Findings

These came out of reading the live estate and testing Caddy 2.11.4 against the probe's own
assertions. They change the plan; they are not chores.

### F1 — `abort` produces curl `52`, which the probe rejects. **Decided: Option A.**

The probe's deny branch accepts `rc = 56` or `code = 403`, and nothing else:

```sh
deny)
  if [ "$rc" = 56 ] || [ "$code" = 403 ]; then verdict=ok
  elif [ "$rc" = 35 ]; then note=' — TLS rejected: no proxy host for this name (deleted?)'
  else note=' — **the Access List did not deny this**'
```

Measured against a real Caddy 2.11.4 with the PROXY listener, replaying the probe's own curl
invocation:

| Caddy deny directive | curl result | probe verdict |
| --- | --- | --- |
| `abort` | `code=000 rc=52` | **FAIL** — "the Access List did not deny this" |
| `respond 403` | `code=403 rc=0` | pass |

nginx `return 444` resets the connection (`56`); Caddy's `abort` closes it cleanly with no data
(`52`). Same intent, different wire shape.

- **Option A (recommended).** Use `abort`, and add `rc = 52` to the probe's deny branch — one
  line — as its **own PR, merged and proven green against NPMplus before cutover**. Amending the
  test while the old system is still the thing under test is what keeps it honest. This is not a
  weakening: `52` means no HTTP response was received at all, and the failure the assertion
  exists to catch (a `200`/`3xx`) is still caught. It preserves today's behaviour — a dropped
  connection on all 21 hosts, which is the `@deny_drop` block the estate normalised by hand on
  2026-08-22 precisely so a refusal does not confirm the vhost exists.
- **Option B.** Use `respond 403`. Zero probe edits, but it downgrades all 21 LAN-only hosts from
  a drop to a fingerprintable `403` — undoing that 2026-08-22 normalisation on every host at once.

**Decided 2026-09-06: Option A.** Option B was the answer only if "the probe must not be
touched" is absolute, and it buys that at the price of a real, if cosmetic, regression across all
21 hosts.

### F2 — Deleting the `npm` stack orphans 17 networks

`stacks/npm/docker-compose.yml` **defines** all 17 `proxy_*` networks with `name:`; the other 16
stacks consume them as `external: true`. This is written into
[`network.md`](../../network.md) → Adding a New Stack as the standing procedure. The `caddy`
stack has to inherit that ownership, and `stacks/npm/` cannot be deleted until it has.

### F3 — Four upstreams are HTTPS with self-signed certs

NPM does not verify upstream certificates. **Caddy does, by default**, and will `502` on all four:

`nas` → `https://192.168.178.111:444`, `portainer` → `https://192.168.178.111:31015`,
`npm` → `https://npm:81`, `goaccess` → `https://npmplus:91`.

Each needs `transport http { tls_insecure_skip_verify }`. The last two disappear with NPMplus, so
two survive the migration.

### F4 — `files` and `auth` are one vhost, and filebrowser is never proxied directly

`1.conf` is `server_name files.example.com auth.example.com` with a single upstream,
`authentik-server-1:9443`. Both names go to the Authentik server; the embedded outpost routes
`files` to filebrowser internally (`internal_host: http://filebrowser:30051` in
[`filebrowser.yaml`](../../../stacks/authentik/blueprints/filebrowser.yaml)).

filebrowser publishes **no host port** and has `FB_AUTH_METHOD: proxy` — it trusts the
`X-authentik-username` header and has no login of its own. Pointing `files.example.com` at
`filebrowser:30051` instead of at the outpost would leave the whole SMB share open to anyone who
can reach the name. The Caddyfile must reproduce `authentik-server-1:9443` verbatim, and the
cutover check for `files` is "an unauthenticated request redirects to Authentik", not "it loads".

### F5 — Anubis is not in use; the CrowdSec move is smaller than the finding implies

`/data/anubis/` holds only the three static images and **zero** generated proxy-host configs
reference it, so the bundled anti-bot carries no migration cost.

CrowdSec enforcement *is* live — `crowdsec.conf` has `ENABLED=true` with a LAPI key, the npmplus
lua bouncer logs `[Crowdsec] Initialisation done`, and acquisition shows 125.46k lines read /
125.46k parsed. AppSec is enabled and pointed at `crowdsec:7422`. So the move is
bouncer-for-bouncer, and [`hslatman/caddy-crowdsec-bouncer`](https://github.com/hslatman/caddy-crowdsec-bouncer)
covers both halves — LAPI remediation (`http` module) and AppSec (`appsec` module). The
`crowdsec` container, its database and its LAPI are untouched by this migration; only the
bouncer changes, and the `ZoeyVid/npmplus` collection/parser is replaced by a Caddy log parser.

### F6 — Per-host certificates would publish the whole internal hostname list

NPM holds one cert: `*.example.com` + `example.com` (verified on
`/data/tls/certbot/live/npm-1/`). If Caddy is left to manage certificates per site block it will
issue 26 individual certificates, and every LAN-only hostname lands in public Certificate
Transparency logs. Caddy **2.10+ prefers an applicable managed wildcard** over a per-subdomain
certificate, so declaring one `*.example.com` site with the DNS challenge keeps a single cert —
but only if the wildcard site is actually declared. Verified: image is `caddy:2-alpine` = 2.11.4.

### F7 — The docs are *not* stale on the host list

The live enumeration and `LAN_ONLY_HOSTS`/`PUBLIC_HOSTS` in the workflow and the access-control
list in [`network.md`](../../network.md) agree exactly: 21 + 5. What is undocumented is the
shape, not the membership — 26 hostnames are served by **25** proxy hosts (F4), and `npm` alone
has no HTTP→HTTPS redirect. No redirection hosts, no dead hosts, no stream hosts exist.

## 3. Host inventory — enumerated from the live NPMplus

Source: `/mnt/apps/npm/npm/data/nginx/proxy_host/*.conf` on the NAS (nginx's own generated
output, i.e. what is actually being served — not the SQLite UI state, and not the docs).
25 files, 26 hostnames.

### Public — no access list (`allow all`)

| Host | Upstream | Notes |
| --- | --- | --- |
| `files` + `auth` | `https://authentik-server-1:9443` | **one vhost** (`1.conf`). F4. |
| `immich` | `http://immich-server-1:30041` | app's own OIDC |
| `mealie` | `http://mealie:9000` | app's own OIDC |
| `jellyfin` | `http://jellyfin:8096` | password endpoints `403` on `:8443` only |

### LAN-only — `allow 192.168.178.0/24; deny 100.64.0.12; allow 100.64.0.0/10; allow 172.16.25.1; deny all; satisfy any;` plus `error_page 401 403 = @deny_drop → 444`

All 21 carry both the access list and the `@deny_drop` block — the 2026-08-22 normalisation held.

| Host | Upstream | Notes |
| --- | --- | --- |
| `adguard` | `http://adguard:30004` | |
| `bazarr` | `http://bazarr:6767` | |
| `beszel` | `http://beszel:8090` | |
| `games` | `http://gamevault-backend:8080` | |
| `goaccess` | `https://npmplus:91` | **backend disappears.** F3, §6 |
| `homarr` | `http://homarr:7575` | |
| `kuma` | `http://uptime-kuma:31050` | |
| `nas` | `https://192.168.178.111:444` | self-signed. F3 |
| `npm` | `https://npm:81` | **backend disappears.** F3, §6 |
| `paperless` | `http://paperless:8000` | |
| `portainer` | `https://192.168.178.111:31015` | self-signed. F3 |
| `prowlarr` | `http://prowlarr:9696` | |
| `qbittorrent` | `http://gluetun:8082` | via gluetun |
| `qdirstat` | `http://qdirstat:3000` | |
| `questarr` | `http://questarr:5000` | |
| `radarr` | `http://radarr:7878` | |
| `romm` | `http://romm:8080` | do not add COOP/COEP |
| `sabnzbd` | `http://gluetun:8080` | via gluetun |
| `seerr` | `http://seerr:5055` | |
| `shelfmark` | `http://shelfmark:8084` | |
| `sonarr` | `http://sonarr:8989` | |

### Diff against the docs

Membership matches [`network.md`](../../network.md) → Access control and the workflow's
`env:` lists exactly — no drift (F7). Deltas worth recording in the doc updates:

- `files`/`auth` share one vhost (F4).
- `npm` serves no HTTP→HTTPS redirect where the other 25 do.
- TrueNAS's web UI on `192.168.178.111:444` is a LAN-reachable port with no row in the
  `network.md` ports table. Not a Docker stack, so `docs-drift.py` cannot see it.

### Listeners and networks to reproduce

Host ports `80`, `81`, `443`, `8443`. `81` is the NPM admin UI and goes away — Caddy has no UI,
which removes the `network.md` bootstrap exception for it.

`:8443` is the PROXY-protocol listener the VPS forwards to. Its socket option is owned by
`/data/custom_nginx/http.conf`; `server_http.conf` is included into every vhost and adds
`listen :8443 ssl` + `set_real_ip_from 100.64.0.12` + `real_ip_header proxy_protocol`. **This
is the trap**: get it wrong and every client IP becomes `100.64.0.12`, which the LAN-only list
denies — so the estate would fail *closed*, loudly, rather than open. The inverse — putting the
PROXY listener's semantics on `:443` — fails open and is the one to guard against.

The 17 networks NPM attaches to, all of which the `caddy` service must join (F2):
`proxy_network`, `proxy_adguard`, `proxy_authentik`, `proxy_beszel`, `proxy_filebrowser`,
`proxy_homarr`, `proxy_immich`, `proxy_kuma`, `proxy_mealie`, `proxy_arr`, `proxy_books`,
`proxy_downloads`, `proxy_games`, `proxy_jellyfin`, `proxy_paperless`, `proxy_qdirstat`,
`proxy_romm`.

`proxy_adguard` is the pinned-subnet one (`172.16.25.0/24`, gateway `172.16.25.1`). Caddy must
join it and keep `allow 172.16.25.1`, or hairpinned internal Kuma checks start failing.

> Mirror the network list **exactly** at cutover, then prune in a follow-up. `proxy_filebrowser`
> is probably droppable — Authentik's server carries it and reaches `filebrowser:30051` itself —
> but proving that belongs after the edge is stable, not during.

## 4. The Caddyfile shape

Validated against Caddy 2.11.4 (`caddy validate` passes; the policy behaviour below was measured,
not assumed — see §5).

```caddyfile
{
	email <acme-contact>

	# Only the :8443 server takes PROXY v1 from the VPS. `proxy_protocol` MUST precede
	# `tls` — it parses plaintext at the head of the connection.
	servers :8443 {
		listener_wrappers {
			proxy_protocol {
				allow 100.64.0.12/32
				fallback_policy reject
			}
			tls
		}
	}

	crowdsec {
		api_url http://crowdsec:8080
		api_key {env.CROWDSEC_API_KEY}
		appsec_url http://crowdsec:7422
	}
}

# One managed wildcard, so LAN-only hostnames stay out of Certificate Transparency (F6).
# Every site block below reuses it; Caddy 2.10+ prefers it over per-subdomain certs.
*.example.com {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
	abort
}

# The whole edge policy, in one place. Order-independent: `remote_ip` lists OR, and the
# matchers in the block AND — so the VPS exclusion cannot be "reordered" into a hole.
(lan_only) {
	@lan {
		remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10
		not remote_ip 100.64.0.12
	}
	handle @lan {
		crowdsec
		reverse_proxy {args[0]}
	}
	handle {
		abort
	}
}

(lan_only_insecure_tls) {
	@lan {
		remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10
		not remote_ip 100.64.0.12
	}
	handle @lan {
		crowdsec
		reverse_proxy {args[0]} {
			transport http {
				tls_insecure_skip_verify
			}
		}
	}
	handle {
		abort
	}
}

# ---- LAN-only (21) ----
adguard.example.com, https://adguard.example.com:8443 {
	import lan_only http://adguard:30004
}
portainer.example.com, https://portainer.example.com:8443 {
	import lan_only_insecure_tls https://192.168.178.111:31015
}
nas.example.com, https://nas.example.com:8443 {
	import lan_only_insecure_tls https://192.168.178.111:444
}
# … 18 more, one line of policy each …

# ---- Public (4 vhosts, 5 names) ----
files.example.com, auth.example.com,
https://files.example.com:8443, https://auth.example.com:8443 {
	crowdsec
	# F4: the Authentik outpost, never filebrowser directly.
	reverse_proxy https://authentik-server-1:9443 {
		transport http {
			tls_insecure_skip_verify
		}
	}
}

# Jellyfin: the edge rule is a separate site block, not a conditional inside one.
jellyfin.example.com {
	crowdsec
	reverse_proxy http://jellyfin:8096
}

https://jellyfin.example.com:8443 {
	crowdsec
	@pw_login      path_regexp (?i)^/(emby/)?users/(authenticatebyname|public)$
	@pw_login_byid path_regexp (?i)^/(emby/)?users/[^/]+/authenticate$
	respond @pw_login 403
	respond @pw_login_byid 403
	reverse_proxy http://jellyfin:8096
}
```

Why this shape:

- **A site block listing both `:443` and `:8443` addresses is split by the adapter into two
  servers** — verified: `srv0 listen [":443"]` with no wrappers, `srv1 listen [":8443"]` with
  the `proxy_protocol` + `tls` wrappers. So `servers :8443` targets only the public listener and
  `:443` never expects a PROXY header. One block per host still gives two correctly-separated
  listeners.
- **`remote_ip` reads "the IP of the immediate peer *or* the address set via PROXY protocol"**,
  so one matcher covers both listeners with no `real_ip` plumbing.
- **The nginx ordering hazard stops being representable.** `deny 100.64.0.12` before
  `allow 100.64.0.0/10` is a sequential first-match rule that a UI edit can silently invert —
  the single most dangerous line in the estate. The Caddy form is a set expression: the CGNAT
  range OR'd, ANDed with `not` the VPS. There is no order to get wrong. The probe still earns
  its keep, because the likelier drift becomes *omitting `import lan_only` on a new host* — and
  `caddy validate` cannot catch that, only the probe can.
- **The Jellyfin rule becomes structural.** Today it is a `map $host:$server_port → $jf_public_edge`
  in `http.conf`, three `if ($uri ~* …)` tests, a synthesised `$jf_edge_block` string compared to
  `"11"`, an internal `rewrite`, and an `error_page 599` trick to stop the host-level `@deny_drop`
  swallowing the `403`. All of that exists to answer "am I on the public edge?". In Caddy the
  public edge *is* a separate site block, so the question does not arise. `/sso/*` and
  `/QuickConnect/*` stay open by simply not being matched.
- **Websockets need no toggle** — `reverse_proxy` upgrades natively. That deletes a documented
  class of failure (`goaccess` freezing, and the "Websockets Support must be on" checkbox).

## 5. What was measured, not assumed

A Caddy 2.11.4 container was run on the A1 with this policy and stub upstreams, and the probe's
own curl invocation (`--haproxy-protocol --haproxy-clientip`) was replayed against it:

| Case | Result |
| --- | --- |
| `portainer` `:8443`, claimed `100.64.0.12` | denied |
| `portainer` `:8443`, claimed `100.64.0.1` | `200` |
| `portainer` `:8443`, claimed `192.168.178.50` | `200` |
| `portainer` `:8443`, claimed `203.0.113.10` | denied |
| public host `:8443`, claimed `203.0.113.10` | `200` |
| `jellyfin` `:8443` `/Users/AuthenticateByName` | `403` |
| `jellyfin` `:8443` `/emby/Users/abc123/Authenticate` | `403` |
| `jellyfin` `:8443` `/Users/Public` | `403` |
| `jellyfin` `:8443` `/users/authenticatebyname` (case) | `403` |
| `jellyfin` `:8443` `/sso/…`, `/QuickConnect/…` | `200` |
| `jellyfin` `:443` `/Users/AuthenticateByName` | `200` — LAN native login intact |
| `:443` + a forged PROXY header | TLS handshake fails (`rc=35`) — **client IP cannot be spoofed** |
| `:8443` from a source outside `allow` | rejected (`rc=35`) |
| `:8443` from an allowed source with no PROXY header | served, using the real peer address (which the LAN-only matcher then denies) |

The `abort` deny shape returned `rc=52` — this is F1, the one result that does not satisfy the
probe as written.

## 6. `npm` and `goaccess` — the two names that lose their backend

Both are in `LAN_ONLY_HOSTS`, so both must keep answering on `:8443` or the probe fails on
`rc=35` (§1). Plan:

- **`goaccess`** — **decided 2026-09-06: placeholder at cutover, decide after the soak.** The
  vhost stays LAN-only and answers `503` to allowed clients. The probe only exercises its **deny**
  direction, so it stays green. Whether GoAccess comes back as its own container — it parses JSON
  natively, so Caddy's default JSON log needs a `--log-format` definition rather than a
  log-format plugin — or the name is retired alongside `npm` is a separate decision after the
  soak, not a migration side effect.
- **`npm`** — Caddy has no admin UI, so the name should be retired. Keep it as a LAN-only vhost
  answering `410` through the cutover and the soak, then remove it in a separate PR that also
  drops it from `LAN_ONLY_HOSTS`, `network.md`, the AdGuard rewrite and the Cloudflare record.
  The probe runbook sanctions exactly this ("intended? update `LAN_ONLY_HOSTS` … and
  `network.md`"). Retiring it *during* the cutover would mix an inventory change into a
  migration, and a red probe would then have two candidate causes.

Net: **zero probe edits are needed for the host inventory.** The only probe change on the table
is the one line in F1.

## 7. Image and stack

The official `caddy` image has neither the Cloudflare DNS provider nor the CrowdSec bouncer, so
one custom build is needed:

```dockerfile
FROM caddy:<pinned>-builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http \
    --with github.com/hslatman/caddy-crowdsec-bouncer/appsec
FROM caddy:<pinned>
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

This is a real cost and worth naming plainly: **the A1's in-house Caddy skill does not cover
this part.** `stacks/a1-vps-matrix/` runs stock `caddy:2-alpine` with HTTP-01, because
`matrix`/`element` are grey-cloud. The NAS edge needs DNS-01 (wildcard, F6) and a bouncer, so it
needs a build pipeline, a registry (ghcr via the existing `github-runner`), and a digest pin that
Renovate can follow. It also moves this stack off the "Renovate bumps the upstream digest" model
that every other stack uses.

Stack layout, following the repo's conventions:

- `stacks/caddy/docker-compose.yml` — the `caddy` service, the `crowdsec` service moved across
  from `stacks/npm/`, and the 17 `proxy_*` network definitions inherited from it (F2).
- The Caddyfile is a real file in `stacks/caddy/Caddyfile`, **not** an inlined `configs:` block —
  the NAS is a local Portainer endpoint, so sibling files work here; the inlining constraint in
  `micro-vps-ingress` is specific to Agent endpoints. One reviewable file is the entire point of
  the finding. Delivery to `/mnt/apps/caddy/` rides the existing on-NAS clone at
  `/mnt/apps/scripts/nas`, the same mechanism the Authentik blueprints use.
- `docs/services/caddy.md`, and `docs/services/npm.md` archived — `docs-drift.py` fails a service
  doc with no matching stack, so these move in the same commit as the stack.
- New CI job: `caddy validate` on the Caddyfile, added to `compose-validate.yml` and made a
  **required check**. That is the half of the finding that git alone does not deliver.

## 8. Cutover and rollback

Sequenced so that every step before the cutover is reversible by doing nothing, and the cutover
itself is reversible by a single Portainer action.

### Phase 0 — prepare (no edge impact)

1. Merge the F1 probe amendment on its own. Run `edge-access-policy.yml` against **NPMplus** and
   confirm it is still green. If it is not, stop — the amendment was wrong.
2. Build and push the custom image; pin by digest.
3. Write `stacks/caddy/` and the Caddyfile; land the `caddy validate` CI check.
4. ZFS snapshot `apps/npm`.

### Phase 1 — parallel run (no edge impact)

Deploy the `caddy` stack joined to all 17 networks, publishing **alternate host ports that map to
the real container ports**:

```yaml
ports:
  - "8080:80"
  - "10443:443"
  - "18443:8443"
```

This matters more than it looks. Caddy still listens on `80`/`443`/`8443` *inside* the container,
so the Caddyfile — including the `servers :8443` block that owns the PROXY-protocol listener
wrapper — is **byte-identical between Phase 1 and Phase 2**. What you test is what ships, and the
cutover collapses to a three-line `ports:` edit. Verified on Caddy 2.11.4: host `18443` →
container `8443` denied a claimed `100.64.0.12` and allowed a claimed `100.64.0.1`, with no
Caddyfile change of any kind.

NPMplus keeps `80`/`81`/`443`/`8443` and keeps serving throughout. Caddy obtains the wildcard over
DNS-01, which needs no inbound port, so the certificate is warm and persisted in its own `/data`
before cutover.

Verify against the alternate ports:

- all 26 names resolve and proxy, `--resolve` against `:10443`;
- `files` redirects an unauthenticated request to Authentik (F4) — the check is the redirect, not
  that the page loads;
- Jellyfin's `:18443` password endpoints `403`, `:10443` `200`;
- the full Layer 2 case list, run from the VPS against `:18443` — the probe script honours
  `NPM_PORT`, so run it as `ubuntu` per the runbook's manual form rather than through the forced
  command. This proves the whole public-path semantics **without touching the VPS**;
- Kuma's internal checks still match `172.16.25.1`.

> **Test from a real LAN or tailnet client, never from the NAS host itself.** A connection from
> the host to a published port is hairpinned and SNAT'd to a Docker bridge gateway, so it arrives
> as the gateway address, not as a LAN IP — measured, and it reads as a spurious deny. This is the
> same mechanism `adguard.md` documents for the pinned `172.16.25.0/24` subnet, and it is why
> `allow 172.16.25.1` has to stay in the matcher. Confirm which gateway Caddy's hairpinned traffic
> actually arrives from before cutover: if it differs from NPM's, Kuma's internal checks and
> Homarr's tiles start being denied *after* the swap, with the 26 public and LAN sites all fine.

### Phase 2 — cutover (the only outage)

1. Stop the `npm` stack in Portainer. **Stop, do not remove** — the networks and `/data` stay.
2. Change the `caddy` service's published ports to `80:80`, `443:443`, `8443:8443`; redeploy.
   Nothing else changes — the Caddyfile is the one Phase 1 proved.
3. Run `gh workflow run edge-access-policy.yml`. Both jobs must be green. This is the gate.
4. Walk the five public names and a handful of LAN-only ones by hand.

**Expected outage: 1–3 minutes**, bounded by stopping NPMplus (~10 s) and recreating the Caddy
container through the normal git → webhook → Portainer path (~1 min; Caddy itself starts in
seconds with its certificate already on disk). Steps 3 and 4 run after service is restored and are
not downtime. A cutover that fails its gate and is rolled back costs roughly 3–5 minutes total.

No VPS change and no DNS change is involved — the VPS still forwards `:80` and `:443`→`:8443` to
the same NAS address, and Cloudflare is untouched. That is what makes the rollback cheap.

### Rollback — NPMplus back inside minutes

At any point in Phase 2, and for the whole soak:

1. Portainer → `caddy` → Stop.
2. Portainer → `npm` → Start.

NPMplus's entire configuration is the `/mnt/apps/npm/npm/data` bind mount, which is never touched
by any step above. Nothing on the VPS, in DNS, in Cloudflare or in Authentik changes, so nothing
has to be reverted there. Re-run the probe to confirm.

The preconditions that keep this true, and that the plan must not break:

- **Do not delete `stacks/npm/` or `/mnt/apps/npm/` until the soak passes.** Keep the stack
  present-but-stopped in Portainer.
- **Do not let the `caddy` stack take over the `proxy_*` network definitions until then either
  (F2)** — deploy Phase 1 with them as `external: true`, and move the definitions across only in
  the post-soak PR that removes `stacks/npm/`.
- Note that `deploy-stacks` auto-revert "blames the last commit", so a bad Caddyfile push during
  the soak reverts the newest stack change, not necessarily the breaking one. Prefer a manual
  Portainer rollback over relying on it.

### Phase 3 — soak, then cleanup

Soak for two weeks — long enough for four scheduled probe runs a day, a Renovate cycle, and a
reboot. Then, as separate PRs: retire `npm.example.com` (§6), remove `stacks/npm/` and move the
network definitions (F2), archive `docs/services/npm.md`, remove the `:81` bootstrap exception
from `network.md`, and prune `proxy_filebrowser` if it proves unnecessary.

## 9. What stays click-ops afterwards

Worth being honest that this closes the edge *policy*, not every click:

| Still click-ops | Why |
| --- | --- |
| Cloudflare DNS records and the orange/grey cloud | no API-managed config in this repo; the probe does assert the cloud colour |
| AdGuard rewrites for `*.example.com` | AdGuard config is UI state — its own instance of GAP-1, untouched by this |
| CrowdSec LAPI bouncer key, Cloudflare DNS token | runtime secrets; they belong in the age vault, not the Caddyfile |
| CrowdSec collections, whitelists, decisions | `cscli` state in `/mnt/apps/npm/crowdsec/config` |
| Portainer stack creation and its git credential | bootstrap; and SVC-2 is where that gets addressed |
| TrueNAS `:444` certificate | not a Docker stack |

What *stops* being click-ops: all 26 proxy hosts, the shared LAN-only access list and its
deny-ordering, the `@deny_drop` blocks, the Jellyfin edge rules, the PROXY-protocol listener, and
the wildcard certificate — roughly 25 UI forms and four hand-edited files under
`/data/custom_nginx/`, replaced by one file with a required `caddy validate` check.

Deliberately **not** done here, and recorded so it is a decision rather than an omission:

- **The port-based `:8443` model** (§1). Serving only the 5 public names on the public listener
  is a stronger invariant than "deny one IP", and Caddy expresses it cleanly. It needs the probe's
  Layer 2 allow-cases redesigned, so it is a follow-up with its own review — not a thing to slip
  into a migration whose acceptance test is the probe.
- **Restoring real client IPs in CrowdSec** — public traffic still arrives as Cloudflare's IP via
  the VPS stream, so CrowdSec still cannot ban individual attackers. That is
  [`micro-vps-ingress.md`](../../services/micro-vps-ingress.md)'s open item and needs an L7 proxy
  on the VPS, not this change.

## 10. Decisions — settled 2026-09-06

| # | Decision | Choice | Consequence |
| --- | --- | --- | --- |
| 1 | Deny shape (F1) | **`abort`, and the probe's deny branch accepts `rc=52`** | Preserves today's dropped connection on all 21 LAN-only hosts, so a refusal still does not confirm the vhost exists. The probe amendment is one token, ships as its own PR, and must be **proven green against NPMplus before Caddy exists** (Phase 0 step 1). |
| 2 | Image and TLS | **Custom `xcaddy` build: `caddy-dns/cloudflare` + `crowdsec-bouncer/{http,appsec}`** | Automatic TLS and CrowdSec enforcement (incl. AppSec) both survive the swap. Accepts the cost in §7: a build pipeline, a ghcr push, a digest pin, and this one stack leaving the Renovate-bumps-upstream-digest model. A Caddy CVE now needs a rebuild, so that path must be documented in `docs/services/caddy.md` before cutover. |
| 3 | GoAccess | **Placeholder `503` vhost at cutover; decide after the soak** | Does not gate the cutover, and the probe stays green because only the deny direction is exercised (§6). Keeps `goaccess.example.com` alive so retiring it stays a reviewed decision rather than a migration side effect. |
| 4 | Soak length | **2 weeks** | ~56 scheduled probe runs, a Renovate cycle, and most likely a reboot, before `stacks/npm/` is removed and the `proxy_*` network definitions move (F2). |

> **Certificate auto-renewal is not proven by any soak of this length.** Caddy renews at roughly
> two-thirds of a 90-day certificate, so a freshly issued one will not renew for ~60 days. That is
> a monitored risk, not something the soak buys — add a Kuma check on certificate expiry for
> `*.example.com` rather than assuming the first renewal will be observed.

## 11. Execution record

### Phase 0 — done 2026-09-06

| Step | Result |
| --- | --- |
| 1. Probe amendment | PR #269, merged alone. Run `34038635082` green against NPMplus, both jobs — 21 denies `rc=56`, both `portainer` allows `200`, `portainer`/`203.0.113.10` deny, 5 public allow. `scripts/edge-access-probe.sh` unchanged, so no VPS re-install |
| 2. Image | `ghcr.io/drizzelat/nas-caddy:2.11.4`, digest-pinned in compose. Package made **public** so the NAS pulls it with no registry credential — its contents are a stock Caddy binary built from public modules |
| 3. Stack + docs + CI | PR #270 — `stacks/caddy/`, [`caddy.md`](../../services/caddy.md), the `caddy-validate` job |
| 4. Snapshot | `apps/npm@pre-caddy-2026-09-06`, a manual name so the 3-day auto-prune leaves it |

### Phase 1 — done 2026-09-06, verified

Stack created with `scripts/secrets.sh push caddy` (CI holds no vault key, by design), then
health-checked by `deploy-stacks` run `34041440042`: *converged: caddy runs the repo pins*.

| Check | Result |
| --- | --- |
| Wildcard certificate | **one** ACME order, `*.example.com`, issued by Let's Encrypt over DNS-01. No LAN-only hostname reaches Certificate Transparency (F6 holds) |
| All 26 names on `:10443` | 24 proxy, `npm` `410`, `goaccess` `503`. Verified **without** `-k`, so the real certificate validates |
| `qdirstat` | `502` — its container is not running. NPMplus `502`s on it too; pre-existing, not a regression |
| `files` | `302 → /flows/-/default/authentication/` — the Authentik outpost, never filebrowser (F4) |
| Jellyfin LAN login | `415` from Jellyfin itself on `:10443`, not a `403` — native password login intact |
| Container hairpin | arrives as **`172.16.25.1`**, measured from inside `uptime-kuma`. Same address NPM sees, so `allow 172.16.25.1` is right and Kuma's checks and Homarr's tiles survive the cutover. Host hairpin arrives as `192.168.178.111` |
| `:18443` from a non-VPS source | rejected, `rc=35` — the listener wrapper's `allow` list holds |
| Forged PROXY header on `:10443` | TLS fails, `rc=35` — the client IP cannot be spoofed on the LAN listener |
| CrowdSec | `caddy-bouncer` registered against the live LAPI, `appsec enabled`, `started`. Caddy also starts with the LAPI unreachable |
| Access log | JSON, landing on `/mnt/apps/caddy/logs/access.log` — ready for the acquisition repoint |
| NPMplus | untouched and healthy; `edge-access-policy.yml` run `34041680404` green with Caddy live in parallel |

### What this plan got wrong

1. **§8 Phase 2 is not a three-line `ports:` edit.** `crowdsec` is part of `stacks/npm`, so
   stopping that stack stops it — but it cannot be added to `stacks/caddy` during phase 1 either:
   `container_name`, the config bind mount and the LAPI port all collide with the running
   container. So the cutover commit is the ports edit **plus** moving the `crowdsec` service
   across, and `stacks/npm` keeps only the `npm` service and the network definitions. Rollback is
   unaffected — starting the npm stack brings crowdsec back with it — but the cutover is a
   two-part edit, not one.
2. **§8 Phase 1's "run the full Layer 2 case list from the VPS against `:18443`" cannot be done.**
   The tailnet ACL admits only `80`/`443`/`8443` from the ingress VPS to the NAS: `nc` from the VPS
   reaches `8443`, and `81`, `31015`, `10443` and `18443` all time out. Measured against the live
   container, not inferred. So the **deny** direction cannot be exercised from a source outside the
   allow list until either the ACL admits the parallel-run port or the cutover puts Caddy on
   `:8443`. What *was* proved without it: the listener wrapper rejects a PROXY header from any
   non-VPS source, and `:443` cannot be spoofed at all.
3. **§4's Caddyfile does not adapt as written.** `crowdsec` and `appsec` are plugin directives with
   no place in Caddy's handler order, so `handle @lan { crowdsec … }` fails with *"directive
   'crowdsec' is not an ordered HTTP handler"*. Fixed with `order crowdsec first` /
   `order appsec after crowdsec` in the global block. Mechanical; no semantic change.
4. **§4 sets `appsec_url` but never calls `appsec`.** The URL alone compiles the module in and
   never invokes it, which would have silently dropped the AppSec half NPMplus has live. The
   `appsec` directive is in the request path, with `appsec_fail_open` — crowdsec stops with its own
   stack, and a restart must not take all 26 sites down.
5. **There is no ACME contact to put in `email`.** NPMplus's Let's Encrypt account has an empty
   contact, so the global option was dropped rather than inventing an address. Certificate expiry
   therefore has no e-mail path at all and needs the Kuma check the §10 note already calls for.

### Also found

An upstream that does not resolve on any `proxy_*` network falls through to the host resolver and
the `example.com` search domain: Caddy dialled `qdirstat` at `198.51.100.30:3000`, a **public
Cloudflare address**. Same under NPM, so not a regression and not fixed here — but a stopped
container turning into an outbound request to a public IP is worth its own look.

### Still open before phase 2 — all closed

- ~~`caddy-validate` is not yet in branch protection's required-check list.~~ It is; this line was
  already stale when written. Required contexts are `validate`, `renovate-review`, `docs-drift`,
  `caddy-validate`.
- ~~The CrowdSec acquisition and parser still point at NPMplus.~~ Repointed, PR #276.
- ~~A Kuma monitor on `*.example.com` certificate expiry.~~ Monitor 41, PR #276.

## 12. Phase 2 execution record — 2026-09-07

**Decision taken before starting: option (b).** The tailnet ACL admits only `80`/`443`/`8443` from
the ingress VPS, so the Layer 2 deny cases could not reach the parallel-run `:18443` (§11, "what
this plan got wrong" #2). The choice was to open the ACL and prove the deny direction first, or
cut over and let the post-cutover probe be the first deny test. **(b) was chosen** — no ACL change,
probe first. It passed, so the risk did not materialise; the exposure was one rollback's worth of
time on a two-click rollback.

### The cutover

| Step | Result |
| --- | --- |
| Cutover commit | PR #275 — ports `80`/`443`/`8443`, `crowdsec` moved into `stacks/caddy` verbatim, `stacks/npm` reduced to the `npm` service + the 17 network definitions, four docs updated |
| Stop `npm` | Portainer stack stop, `/api/stacks/35/stop`. **This is a `compose down`, not a `stop`** — see #6 below |
| Deploy `caddy` | `deploy-stacks` dispatched with `stacks=caddy reconcile=false`, run `34108468076`. Caddy up on `80`/`443`/`8443` |
| Gate — `edge-access-policy.yml` | Run `34108562532`, **both jobs green, 29 cases**. First deny test ever run against Caddy: 21 LAN-only hosts claiming `100.64.0.12` → `rc=52`; `portainer` claiming `100.64.0.1` and `192.168.178.50` → `200`; `portainer` claiming `203.0.113.10` → `rc=52`; 5 public claiming `203.0.113.10` → `200`/`302`. **F1's `rc=52` amendment was right** |
| Hand walk | From `192.168.178.24`, a real LAN client, **without `-k`**: 5 public + 10 LAN-only correct. `files` → `302 /outpost.goauthentik.io/start` (F4 holds). `goaccess` `503`, `npm` `410`. Jellyfin `POST /Users/AuthenticateByName` on `:443` → `400` *from Jellyfin*, not `403` — native LAN login intact |
| CrowdSec repoint | PR #276. `cscli metrics show acquisition`: **52 read, 52 parsed, 0 unparsed** on `/var/log/caddy/access.log`. `caddy-bouncer` valid with a recent pull |
| Kuma | Monitor 41, *Caddy wildcard cert (\*.example.com)*, hourly, expiry notification on, Discord attached. `monitor_tls_info` shows the real cert: `*.example.com`, Let's Encrypt, expires 2026-12-05 |

Outage was a single deploy cycle. Nothing on the VPS, in DNS, in Cloudflare or in Authentik was
touched, as planned.

### What this plan got wrong, continued

6. **Portainer's stack stop is `docker compose down`, not `docker compose stop`.** The containers
   are *removed*, not left exited. This was the difference between a clean cutover and a blocked
   one: a stopped container still holds its name, and `container_name: crowdsec` in the caddy
   stack would have collided with a lingering `crowdsec` from the npm stack. It did not, so the
   verbatim move worked with no fixup and the rollback stays two clicks. It also means the 17
   `proxy_*` networks survived only because **Caddy holds endpoints on them** — Docker refuses to
   remove a network in use. Had the cutover been attempted with Caddy stopped, `down` would have
   taken the network definitions with it.
7. **"Move `crowdsec` verbatim" and "repoint the acquisition" are in tension.** Verbatim is right
   for the cutover commit — it keeps that commit a pure move — but the three bind mounts give the
   container no view of `/mnt/apps/caddy/logs`. The repoint needs a **fourth** mount,
   `/mnt/apps/caddy/logs:/var/log/caddy:ro`, so it is necessarily a second commit (PR #276), not
   part of the cutover.
8. **A push touching both stack folders would have fired the `npm` webhook.** `deploy-stacks`
   derives its stack list from the pushed paths, so merging the cutover normally would have run
   `compose up` on npm while Caddy held `:80` — a port collision, and the health check's
   auto-revert would then have blamed the cutover commit. The cutover merge therefore carried
   `[skip ci]` and the deploy was a `workflow_dispatch` with `stacks=caddy`; dispatched stacks are
   explicitly not rollback candidates in `verify-healthy.sh`.

9. **Nothing in the plan owns host-side config that names a container.** The `nas`
   healthchecks.io dead-man's switch guards on a container name in
   `/root/.config/healthchecks-guard.container`, which still said `npmplus`. No deploy
   touches it — it lives beside the ping URL so one script serves every host — so the
   check went red on the next cron tick, well after the probe and the hand walk had both
   passed. Fixed to `caddy`; see [external-heartbeat.md](external-heartbeat.md). **A
   rollback to NPMplus has to flip it back**, or the check pages through a deliberate
   rollback. Worth asking, before any future swap, what *else* names the outgoing
   container outside the repo.

### Also confirmed

- **`appsec_fail_open` earned its keep on day one.** Recreating the `crowdsec` container for PR
  #276 produced ~60 s of `appsec component unavailable — connection refused` in Caddy's log with
  **no site interruption**. Without it, a routine CrowdSec restart would take all 26 sites down.
- Only the changed service was recreated by the redeploy: `crowdsec` restarted, `caddy` kept its
  uptime. A CrowdSec-only change costs no edge downtime.
- Two collections had to be named explicitly. `crowdsecurity/appsec-virtual-patching` and
  `crowdsecurity/appsec-generic-rules` reached the box as *dependencies* of `ZoeyVid/npmplus`, and
  `appsec-configs/local-nas.yaml` needs their `vpatch-*` / `generic-*` rules. `ZoeyVid/npmplus`
  itself stays installed — `cscli collections remove` would take them with it.
- `acquis.d/npm.yaml` and the `/var/log/npm` mount were left in place. The file is static now, and
  a rollback gets NPMplus's detection back with no config work.

### Still open before phase 3's cleanup — all closed

~~The soak runs to 2026-09-21.~~ Skipped — see §13.

## 13. Phase 3 execution record — 2026-09-07

**The soak was skipped by decision**, hours after the cutover rather than two weeks after it. The
argument for skipping: the soak's stated value was ~56 probe runs, a Renovate cycle and a reboot,
and the one thing it could never buy is a certificate renewal (§10 note) — Caddy renews at ~30 days
remaining, and the live wildcard expires 2026-12-05. Monitor 41 is the control for that either way,
soak or no soak. What was given up is the cheap rollback, which is a real cost and is written up
below.

### The cleanup, in order

| PR | What | Verified |
| -- | ---- | -------- |
| #279 | `stacks/caddy` takes the 17 `proxy_*` network definitions, verbatim | `compose up --dry-run` first; after merge, no container restarted and all 17 networks kept their endpoints |
| #280 | `stacks/npm/` deleted, `docs/services/npm.md` → `docs/archive/`, the NPM-flavoured prose across seven docs retargeted | `deploy-stacks` logged `OK: deleted npm`; 17 networks survived the `compose down` |
| #281 | `npm.example.com` retired; probe job renamed `edge-access-list` | `edge-access-policy.yml` green; hand-walked from `192.168.178.24` |

Ordering mattered: #279 had to land before #280, or deleting the stack would have orphaned the
networks (F2).

### What this plan got wrong, continued

10. **`proxy_filebrowser` is not prunable, and §3's note is wrong to call it "probably
    droppable".** Caddy genuinely never proxies filebrowser directly — the note is right about
    that. But compose **only creates a network some service attaches to**; a definition nothing
    joins is silently skipped. Verified with a second `--dry-run`: a declared-but-unused network
    produced no `Creating` line at all. Since `stacks/caddy` now owns the definition, dropping
    caddy's membership would leave the network ownerless and a from-scratch bring-up would fail
    with filebrowser and authentik both consuming it as `external: true`. Caddy stays joined. The
    alternative — move the definition into `stacks/filebrowser`, which is the stack that actually
    needs it — is a change to the hub-and-spoke convention and was left alone.
11. **The network ownership move was safe, and the plan never said whether it would be.** Compose
    adopts an existing network carrying another project's labels: it warns `a network with name
    proxy_adguard exists but was not created for project "caddy"` and attaches anyway. No recreate
    is attempted, so nothing detaches. The corollary is permanent: the 17 networks keep
    `com.docker.compose.project=npm` forever, because nothing will recreate them while containers
    hold endpoints. The warning on every `caddy` deploy is cosmetic.
12. **§6's "the AdGuard rewrite and the Cloudflare record" for `npm.example.com` do not exist.**
    Both cover `*.example.com` with a wildcard. `dig +short @1.1.1.1 npm.example.com A` returns
    the same Cloudflare addresses as every other LAN-only name. There was no per-name record to
    delete, so the retirement needed **zero click-ops** — the one step in this whole migration the
    plan expected to be manual and wasn't.
13. **A Caddyfile-only change does not deploy itself, and the fix is a container restart.** This
    cost the most time of anything in phase 3. The chain: `git pull` in the on-NAS clone *replaces*
    the file, a single-file bind mount is bound to the **inode**, so the container keeps reading the
    old file indefinitely — the 15-minute pull the docs pointed at is necessary and not sufficient.
    The Portainer redeploy `deploy-stacks` fires does not help either: compose sees an unchanged
    service and leaves the container running. Worst of all, `docker exec caddy caddy reload`
    re-reads the *stale* mounted file, logs `adapted config to JSON`, and exits `0` having changed
    nothing — a green no-op. The npm vhost was still answering `410` from a LAN client through two
    "successful" reloads. Only `docker restart caddy` worked. **Fixed the same day**: the mount is
    now the directory `/etc/caddy`, whose inode is stable across a pull, and `git-pull-nas.sh`
    runs `caddy reload` when a pull moves the Caddyfile. An edge policy change now deploys itself
    within 15 minutes with no restart and no dropped connection.
14. **A retired name does not 404.** TLS completes — the wildcard certificate is in Caddy's cache
    and matches — and then no site block does, so the request is refused with no HTTP status:
    `curl` exit 92, `%{http_code}` `000`. This is why a name in `LAN_ONLY_HOSTS` with no vhost
    fails the probe instead of reading as a deny, which is what kept `npm` and `goaccess` alive as
    `410`/`503` placeholders through the cutover in the first place.
15. **Caddy does not pass the client's `Host` to an upstream written as a URL — it sends the
    upstream's own address.** `nas.example.com` was the one host this shows on: TrueNAS's nginx
    builds its `/` → `/ui/` redirect from `$http_host`, so the browser was bounced to
    `https://192.168.178.111:444/ui/` — the raw IP on TrueNAS's self-signed certificate, a
    certificate warning on every visit. NPMplus preserved the header, so this arrived with the
    cutover and nothing in the acceptance test caught it: the probe asks for a status, and `302`
    is one. Fixed 2026-09-08 with `header_up Host {host}` in the `lan_only_insecure_tls` snippet,
    confirmed against a throwaway Caddy running both settings side by side.

### Also confirmed

- `fire-webhooks.sh` deletes the Portainer stack for a removed folder by itself (Pass 1), so
  AGENTS.md's "Remove stack in Portainer" step is automated. `compose down` for project `npm` then
  tried to remove the 17 networks and Docker refused — containers held endpoints — which is the
  intended outcome and the reason #279 came first.
- The probe job `npm-access-list` was **not** a required status check (`validate`,
  `renovate-review`, `docs-drift`, `caddy-validate` are), so renaming it to `edge-access-list`
  broke no branch protection.
- 20 LAN-only names and 5 public ones remain, 25 total, in 24 site blocks — `auth` and `files`
  share one (F4).

### What the rollback costs now

Removing `stacks/npm/` deleted the Portainer stack with it, so rollback is no longer `npm` → Start:
revert #280, stop `caddy`, deploy `npm`, flip the heartbeat guard back. Roughly 15 minutes instead
of two. It is not lossy — `/mnt/apps/npm/npm/data` is untouched, `apps/npm@pre-caddy-2026-09-06`
still exists, and nothing on the VPS, in DNS, in Cloudflare or in Authentik ever changed. A naive
revert does collide on `container_name: crowdsec`; the procedure in
[caddy.md](../../services/caddy.md) says so.

### Still open, deliberately

- **`goaccess.example.com` is a `503` placeholder.** Whether GoAccess returns as its own
  container is a standalone decision, not migration debt.
- **`acquis.d/npm.yaml` and the `/var/log/npm` mount** on `crowdsec` are still in place. They cost
  nothing, the file is static, and a rollback gets NPMplus's detection back with no config work.
- **`qdirstat` 502s through the proxy**, and did under NPMplus too. Pre-existing, out of scope.

### Found afterwards — apps that pin the proxy's IP in their own config

The migration moved every proxy IP, and an app that stores the trusted-proxy address in its **own
config state** keeps pointing at the retired NPM subnet. Nothing in this repo covers that state, so
the acceptance test passed while the app was quietly broken.

Hit on 2026-09-08: Jellyfin's `KnownProxies` still read `172.16.23.0/24` (NPM) while Caddy fronted
it from `proxy_jellyfin`. Untrusted proxy ⇒ `X-Forwarded-Proto` ignored ⇒ `Request.Scheme` = `http`
⇒ the SSO plugin built an `http://` redirect URI and Authentik rejected it `strict`. Jellyfin SSO
had been unusable since cutover; only local password login still worked, which is why nothing
alerted. Fixed by setting `KnownProxies` to `172.16.33.0/24` + `fdd0:0:0:21::/64` and restarting.

Worth sweeping the other proxied apps for the same class of setting (trusted proxies / real-IP /
allowed hosts) held in app config rather than in `stacks/`.

## Last updated

2026-09-08
