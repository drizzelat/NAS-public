# Service: Caddy (edge reverse proxy)

## Overview

Caddy terminates TLS for every `*.example.com` hostname and proxies it to the container
behind it. It replaced **NPMplus** ([archive/npm.md](../archive/npm.md)), whose entire configuration was UI state
in a bind mount that nothing reviewed —
[GAP-1](../architecture-review-2026-08-20.md#gap-1--npm-and-authentik-config-is-click-ops) /
[SVC-1](../architecture-review-2026-08-20.md#svc-1--npmplus--caddy). The whole edge policy is now
one reviewable file, [`stacks/caddy/Caddyfile`](../../stacks/caddy/Caddyfile), with a
`caddy validate` required check on every pull request.

Public internet traffic reaches it from the **Oracle VPS** front door over Tailscale — see
[micro-vps-ingress.md](micro-vps-ingress.md). Nothing about that path changed in the migration:
no VPS, DNS, Cloudflare or Authentik change was needed.

> **Caddy has owned the edge since 2026-09-07**, serving every request on `:80`/`:443`/`:8443`.
> The `npm` stack was removed the same day — the soak was skipped by decision, not by oversight.
> See [Cutover](#cutover-and-rollback) and the
> [execution record](../runbooks/setup-operations/caddy-migration.md#11-execution-record).

## Stack

Two containers:

| Container | Role |
| --------- | ---- |
| `caddy` | the edge reverse proxy — TLS, access policy, all 25 hostnames |
| `crowdsec` | intrusion detection / IP reputation, and the LAPI this stack's bouncer queries |

- **Stack folder:** `stacks/caddy/`
- **Compose file:** `stacks/caddy/docker-compose.yml`
- **Deploy:** Komodo Stack `caddy` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
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

The parallel run published these same container ports as `8080`/`10443`/`18443`, so the Caddyfile
— including the `servers :8443` block that owns the PROXY-protocol listener wrapper — is
byte-identical to the one that was tested. What shipped is what was verified.

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/etc/caddy` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/caddy` | The edge policy, from Komodo's clone on the NAS. The **directory** — see the note below |
| `/data` | `/mnt/apps/caddy/data` | Certificates, ACME account, OCSP staples |
| `/config` | `/mnt/apps/caddy/config` | Caddy's autosaved JSON config |
| `/var/log/caddy` | `/mnt/apps/caddy/logs` | Access log (JSON), read by CrowdSec and by [Vector](observability.md) |
| `/var/lib/crowdsec/data` | `/mnt/apps/npm/crowdsec/data` | CrowdSec database |
| `/etc/crowdsec` | `/mnt/apps/npm/crowdsec/config` | CrowdSec configuration |
| `/var/log/caddy` (`ro`) | `/mnt/apps/caddy/logs` | the access log again, this time as CrowdSec reads it |
| `/var/log/npm` (`ro`) | `/mnt/apps/npm/npm/data/nginx/logs` | NPMplus's logs, static since the cutover — kept so a rollback keeps its acquisition |

> CrowdSec's three paths still live under `/mnt/apps/npm/`. Renaming them is a data migration, not
> a cutover step, and it was left out of the npm teardown on purpose; the `/var/log/npm` mount can
> go at the same time, once the NPMplus rollback path below is given up.

> **A merged Caddyfile change is live as soon as `deploy-stacks` has deployed `caddy`, with no
> restart and no dropped connection.** The Caddyfile is bind-mounted out of Komodo's clone at
> `/mnt/apps/komodo/repos/nas`, which the deploy pulls. The Stack's `post_deploy`
> ([`komodo/resources.toml`](../../komodo/resources.toml)) then does two things, and either one
> failing fails the deploy:
>
> 1. **Checks the mount.** The Caddyfile inside the container must be byte-identical to the
>    clone's. A fresh clone would leave the mount on the deleted directory (komodo-migration.md F28).
> 2. **Runs `caddy reload`.**
>
> Moved there from `git-pull-nas.sh`'s 15-minute pull on 2026-09-17 (CPX-2 #4a). The same deploy
> also delivers the [Authentik blueprints](authentik.md#configuration-in-git-blueprints).
>
> **The mount is the directory, `/etc/caddy`, not the file.** This is load-bearing. `git` replaces
> the Caddyfile rather than rewriting it, and a single-file bind mount is bound to the inode — so
> with the old file mount the container read the *original* file forever, and `caddy reload`
> re-read that stale copy, logged `adapted config to JSON` and exited `0` having changed nothing.
> A green no-op. Fixed 2026-09-07; migration record, finding 13.
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

Set as Komodo Variables `CADDY__<KEY>` (`scripts/secrets.sh push caddy`); the plaintext lives in the gitignored `secrets/portainer-env/caddy.env`
and the ciphertext in `secrets.enc/` — see the [secret-sync runbook](../runbooks/setup-operations/secret-sync.md).

| Variable | Description |
| -------- | ----------- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare DNS-edit token for the DNS-01 challenge. Same token NPMplus used |
| `CROWDSEC_API_KEY` | LAPI key for this bouncer — `cscli bouncers add caddy-bouncer` |

There is deliberately **no ACME contact address**, matching NPMplus. Nothing e-mails you about a
failing renewal, so certificate expiry is a Kuma check, not an assumption — *Caddy wildcard cert
(\*.example.com)*, see the [kuma-monitors runbook](../runbooks/setup-operations/kuma-monitors.md).
It notifies at 21/14/7 days remaining, all of which are past the point Caddy should have renewed,
so it fires only when renewal has already failed.

## The edge policy

### One wildcard certificate, not 25

The Caddyfile declares a single `*.example.com` site with the Cloudflare DNS challenge. Caddy
prefers an applicable managed wildcard over issuing per-subdomain certificates, so all 25
hostnames share that one cert — verified: a cold start attempts exactly one order, for
`*.example.com`. This is not cosmetic. Per-site certificates would publish every LAN-only
hostname into public Certificate Transparency logs.

That site block also **default-denies**: any `*.example.com` name with no block of its own gets
`abort`.

### LAN-only vs public

21 hostnames are LAN-only, 5 are public (`auth`, `files`, `immich`, `jellyfin`, `mealie`). The
full per-host list is the access-control section of [network.md](../network.md), and
[`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml) asserts it every 6 h.

LAN-only hosts import one snippet:

```caddyfile
@lan {
	remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10
	not remote_ip 100.64.0.12
}
```

- `100.64.0.12` is the ingress VPS's tailnet IP, and it sits **inside** the allowed CGNAT range
  `100.64.0.0/10`. Excluding it is what keeps LAN-only admin UIs off the public internet.
- In NPM this was a **sequential** `allow`/`deny` list where the deny had to come first, and a UI
  edit could silently invert it. Here the IP lists OR, the two matchers AND, and `not` is not
  positional — there is no order to get wrong.
- `172.16.25.1` is the `proxy_adguard` gateway, which is what hairpinned internal traffic (Uptime
  Kuma's checks, Homarr's tiles) looks like to the proxy. Removing it breaks those while all 25
  sites still look fine from a browser.

A non-matching client gets `abort` — the connection is closed with no HTTP response, so a refusal
does not confirm the vhost exists. On the wire that is **curl exit 52**, where nginx's `return 444`
was exit 56; the probe accepts both, see the
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

**The policy on `:8443` is client-IP-based for all 25 names, not port-based.** Serving only the 5
public names there is a stronger rule and Caddy expresses it cleanly, but it changes what the probe
asserts, so it is a follow-up with its own review — not part of this migration.

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
  2026-09-09. A module that fetches them at startup would let a failed fetch hold all 25 sites
  down, which is the same failure the `appsec_fail_open` decision avoids. Re-check the list when
  Cloudflare announces a change.
- `jellyfin` is gray-cloud, so its requests already arrived with the visitor's address and are
  unaffected.

### Jellyfin's public edge

Jellyfin's password endpoints are blocked at the public edge only, so the web UI logs in through
Authentik while Seerr and native apps keep using local credentials on the LAN — see the
[jellyfin-authentik-sso runbook](../runbooks/setup-operations/jellyfin-authentik-sso.md). In NPM
this needed a `map`, three `if` tests, a synthesised string comparison and an `error_page 599`
trick to answer "am I on the public edge?". Here the public edge *is* a separate site block
(`https://jellyfin.example.com:8443`), so the question never arises. `/sso/*` and
`/QuickConnect/*` stay open by not being matched.

### Immich's public edge

Same shape, same reason, added 2026-09-16. `immich.example.com` is now two site blocks instead of
one: LAN/tailnet `:443` proxies straight through, and the public `:8443` twin returns `403` for

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

Caddy verifies upstream certificates by default; nginx did not. Two upstreams serve a self-signed
cert and would `502` without `transport http { tls_insecure_skip_verify }`:
`nas` (`https://192.168.178.111:444`), and the Authentik outpost (`https://authentik-server-1:9443`).
`portainer` (`:31015`) was the third until its removal on 2026-09-17.

### The TrueNAS UI needs the original `Host`

The same snippet also sets `header_up Host {host}`. Caddy sends the **upstream** address as the
`Host` header when the upstream is written as a URL, and TrueNAS's own nginx builds its
`/` → `/ui/` redirect straight from it (`rewrite ^.* $scheme://$http_host/ui/ redirect;`) — so
`https://nas.example.com/` bounced the browser to `https://192.168.178.111:444/ui/`, the raw IP
on TrueNAS's self-signed certificate, and every visit ended on a certificate warning. NPMplus
preserved the header, so this arrived with the cutover. Verified against a throwaway Caddy on
both settings; migration record, finding 15.

The plain `lan_only` snippet is untouched — no upstream behind it redirects by
host.

### `files` is proxied straight to the app

`files.example.com` reverse-proxies to `http://files:30052` — [FileBrowser Quantum](files.md) —
with the Authentik outpost **not** in the path. Quantum runs the OIDC flow itself, and that is the
point: public share and upload links have to resolve without an Authentik session.

Until the 2026-09-09 cutover this name shared one vhost with `auth.example.com` and both went to
`https://authentik-server-1:9443`, because the old filebrowser ran `FB_AUTH_METHOD: proxy` and had
no login of its own — proxying it directly would have opened the whole SMB share. That constraint
is gone with the app. The two names are separate vhosts now; `auth` still goes to the outpost.
[Migration runbook](../runbooks/setup-operations/filebrowser-to-quantum.md).

### `grafana`, and the retirement of `goaccess`

`goaccess.example.com` was a backend-less `503` placeholder from the cutover until 2026-09-09,
held open only because a name in `LAN_ONLY_HOSTS` with no vhost fails TLS (curl 35) and the probe
correctly reads that as a failure. The question it left open — whether GoAccess returns as its own
container — was answered no: it is replaced by
[`grafana.example.com`](observability.md), a normal `lan_only` vhost to
`http://grafana:3000`. The `goaccess` vhost is deleted and the name dropped from `LAN_ONLY_HOSTS`
and [network.md](../network.md), exactly as `npm` was.

That leaves `lan_only_status` defined with no user. It is the documented shape for "the name must
stay listed but the backend is gone", so it is kept rather than re-derived next time.

`npm.example.com` was retired on 2026-09-07: vhost deleted, dropped from `LAN_ONLY_HOSTS` and
[network.md](../network.md). Nothing was needed at Cloudflare or AdGuard — both cover
`*.example.com` with a wildcard, so there was never a per-name record, contrary to the plan.

The name still resolves. TLS still completes, because the wildcard certificate is in Caddy's cache
and matches — but no site block does, so the request is refused with no HTTP status at all
(`curl` exit 92, `%{http_code}` `000`). That is the shape of every retired name from here on, and
it is why a name listed in `LAN_ONLY_HOSTS` without a vhost fails the probe rather than reading as
a deny. The VPS SNI allowlist keeps it off the internet exactly as before.

## Image

The official `caddy` image has neither the Cloudflare DNS provider nor a CrowdSec bouncer, so this
stack runs a custom `xcaddy` build from [`stacks/caddy/Dockerfile`](../../stacks/caddy/Dockerfile):

| Module | Why |
| ------ | --- |
| `caddy-dns/cloudflare` | DNS-01 for the wildcard — HTTP-01 cannot issue one |
| `hslatman/caddy-crowdsec-bouncer/http` | LAPI remediation, replacing the NPMplus lua bouncer |
| `hslatman/caddy-crowdsec-bouncer/appsec` | the AppSec half, which NPMplus also had enabled |

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

- The 19 `proxy_*` Docker networks: `proxy_network` (CrowdSec, and the `victoriametrics` scrape)
  plus one per proxied stack. This stack **defines** them since
  2026-09-07; every other stack consumes them as `external: true`. Adding one is
  [network.md](../network.md) → Adding a New Stack.
- `proxy_observability` was added on 2026-09-09 with the
  [observability stack](observability.md). That stack also reads
  `/mnt/apps/caddy/logs/access.log` — a second reader alongside CrowdSec, which is not a conflict —
  and puts `victoriametrics` on `proxy_network` to scrape `crowdsec:6060`.
- `proxy_komodo` was added on 2026-09-15 for the LAN-only `komodo.example.com`, ahead of the
  Komodo Core stack that joins it ([komodo-migration.md](../runbooks/setup-operations/komodo-migration.md)
  §8 Phase 1). Until Core runs, that name answers `502` on the LAN.
- `proxy_filebrowser` was dropped on 2026-09-09 with the filebrowser stack. It was the one
  network Caddy defined and joined without proxying anything through it — the migration record's
  finding 10 explains why it could not simply be un-joined while it existed. The Docker network
  itself may linger as an orphan on the host until pruned.
- `crowdsec`, in this stack since the cutover, reached as `crowdsec:8080` (LAPI) and
  `crowdsec:7422` (AppSec) over `proxy_network`. It moved out of `stacks/npm` because stopping
  that stack stops it. Its data and config bind mounts still point under `/mnt/apps/npm/`.
- **Public reachability** depends on the [VPS ingress](micro-vps-ingress.md) + Tailscale.

## Notes

- **CrowdSec's parser changes with the proxy.** The `ZoeyVid/npmplus` collection parses NPMplus's
  log format and parses **nothing** from Caddy's JSON access log. It is swapped for a Caddy parser
  and the acquisition repointed at `/mnt/apps/caddy/logs/access.log` — see the
  [crowdsec-bouncer runbook](../runbooks/setup-operations/crowdsec-bouncer.md). Verify with
  `cscli metrics show acquisition`: "Lines parsed" must be non-zero.
- **AppSec fails open** (`appsec_fail_open`). CrowdSec stops with its own stack, and a restart must
  not take all 25 sites down with it. LAPI remediation is unaffected.
- Caddy starts even when the LAPI is unreachable (`enable_hard_fails` is off), which is what makes
  the cutover order safe.
- **Websockets need no toggle** — `reverse_proxy` upgrades natively. The NPM-era "Websockets
  Support must be on" failure class is gone.
- `crowdsec` and `appsec` are plugin directives with no place in Caddy's built-in handler order,
  hence `order crowdsec first` / `order appsec after crowdsec` in the global block. Without them
  the directives are only usable inside a `route`.
- Anubis (the NPMplus anti-bot) was never in use — zero generated configs referenced it — so it
  carries no migration cost.

## Operations

> Restart/redeploy go through **Komodo** (Stack `caddy`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless
> sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `caddy` → **Deploy**, or push to `stacks/caddy/` → the runner deploys it through
  Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). Every Komodo deploy ends
  with the Stack's `post_deploy` `caddy reload`, and a failing reload fails the deploy. A recreate costs every site a stop timeout plus start (~20 s measured
  on the LAN, 2026-09-15).
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

The `caddy-validate` job in [`compose-validate.yml`](../../.github/workflows/compose-validate.yml)
is a **required check**. By hand, with the same image the stack runs:

```sh
docker run --rm -e CLOUDFLARE_API_TOKEN=$(head -c 30 /dev/urandom | base64 | tr -d '+/=' | head -c 40) \
  -e CROWDSEC_API_KEY=x -v "$PWD/stacks/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  ghcr.io/drizzelat/nas-caddy:<tag> caddy validate --config /etc/caddy/Caddyfile
```

The Cloudflare token has to *look* like one (40 chars, `[A-Za-z0-9_-]`) — the provider rejects
obvious placeholders before the config is judged valid.

### Cutover and rollback

Full plan: [caddy-migration.md](../runbooks/setup-operations/caddy-migration.md).

| Phase | What |
| ----- | ---- |
| 1 | Caddy ran on `8080`/`10443`/`18443` while NPMplus kept `80`/`81`/`443`/`8443` and kept serving. Done 2026-09-06 |
| 2 | Stopped (**not removed**) the `npm` stack, moved `crowdsec` into this stack, republished `80:80`, `443:443`, `8443:8443`, repointed the CrowdSec acquisition. `edge-access-policy.yml` green, both jobs, was the gate. Done 2026-09-07 |
| 3 (now) | Soak skipped by decision. `stacks/caddy` took the `proxy_*` network definitions, `stacks/npm/` was deleted and its doc archived. Done 2026-09-07 |

**Rollback is no longer a Portainer Start.** Removing `stacks/npm/` deleted the Portainer stack
with it, and CI will not recreate it: `npm` is on `CREATE_SKIP` in
[`fire-webhooks.sh`](../../scripts/deploy/fire-webhooks.sh), and its env lives in the vault
(`secrets.enc/portainer-env/npm.env.age`), which CI cannot decrypt. Going back to NPMplus
therefore means:

1. Komodo → `caddy` → **Stop** (both cannot hold `:80`, and `crowdsec` must free its
   `container_name`).
2. Revert the removal commit — it restores `stacks/npm/` with `crowdsec` inside it, so take
   `crowdsec` out of `stacks/caddy` in the same commit — and push it with `[skip ci]`, so
   `deploy-stacks` does not redeploy the stopped `caddy` stack.
3. From a workstation: `scripts/secrets.sh push npm`, which creates the `npm` stack from the repo
   with its vault env and deploys it.
4. Flip the heartbeat guard back, or the `nas` check on healthchecks.io goes red:
   `sudo sh -c 'echo npmplus > /root/.config/healthchecks-guard.container'`
   ([external-heartbeat.md](../runbooks/setup-operations/external-heartbeat.md)).

That is roughly 15 minutes rather than two, but it is not lossy: NPMplus's whole configuration is
`/mnt/apps/npm/npm/data`, which no step above touches, there is a pre-cutover snapshot at
`apps/npm@pre-caddy-2026-09-06`, and nothing on the VPS, in DNS, in Cloudflare or in Authentik ever
changed.

Note that `deploy-stacks` auto-revert **blames the last commit**, so a bad Caddyfile push reverts
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
- **CrowdSec stops detecting after cutover** → the acquisition still points at the NPMplus log, or
  the `ZoeyVid/npmplus` parser is still installed. See Notes.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack with its `post_deploy` reload, env from Komodo Variables. `qdirstat` vhost and network removed (#380).

2026-09-15
