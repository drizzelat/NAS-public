# Service: VPS ingress (Oracle Cloud)

## Overview

Public entry point for the whole setup. The NAS sits behind CGNAT/FritzBox with **no inbound
port-forward**, so it has no public IP of its own. A small Oracle Cloud VPS holds the public IP,
accepts public `:80/:443`, and forwards the raw TCP streams to [Caddy](caddy.md) on the NAS **over
Tailscale** (WireGuard). No TLS termination on the VPS — SNI/HTTPS pass straight through, and Caddy
terminates the `*.example.com` wildcard cert.

`*.example.com` is **proxied through Cloudflare** (orange-cloud) — except `jellyfin`, which is
gray-cloud (DNS-only) because it streams video (Cloudflare ToS §2.8). For the orange-clouded names
the public DNS records resolve to **Cloudflare anycast IPs**, Cloudflare terminates the client TLS
with its own edge cert and **origin-pulls** to the **VPS public IP** (`198.51.100.10`); `jellyfin`
resolves to the VPS directly. The full internet path is therefore
**(Cloudflare edge →) VPS nginx (stream) → Tailscale → Caddy `:8443`**. LAN/tailnet clients hit
Caddy `:443` directly (AdGuard rewrites the names to the NAS IP) and never touch Cloudflare or the
VPS.

**Cloudflare is in front, so error pages differ from a raw nginx.** When the VPS closes a
connection (SNI not in the allowlist), Cloudflare cannot complete the origin TLS handshake and the
client sees **`525`** — verified against every LAN-only hostname, not a bare TCP reset and not a
`520`. That is the healthy signal. If a request instead reaches Caddy and its `@lan` matcher refuses
it, Caddy `abort`s the connection with no HTTP response, which Cloudflare shows as a `520`. See the
"anything other than `525`" entry under Common failures — **any** Caddy-shaped answer on a LAN-only
host means the VPS SNI allowlist is **not actually deployed** (blind-forward), so the request leaked
all the way to Caddy.

> Both layers are asserted every 6 h by
> [`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml) —
> [runbook](../runbooks/setup-operations/edge-access-policy-probe.md).

> **Komodo Stack, since 2026-09-15.** The `nginx` ingress lives in this repo at
> [`stacks/micro-vps-ingress/`](../../stacks/micro-vps-ingress/) (single self-contained
> `docker-compose.yml` — the nginx config is **inlined as a Compose `config`**, see note below). It
> is deployed by the Komodo Stack `micro-vps-ingress` on Server `micro-vps`, through the
> [periphery](micro-vps-periphery.md), from the clone at `/etc/komodo/repos/nas`. A push reaches it
> through `deploy-stacks` → Komodo `DeployStack`, with the health gate; the hourly
> `reconcile-owned` Procedure is the backstop ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).
> The stack has no env, so it uses no Komodo Variables.
>
> **Why the config is inlined, not a mounted file:** this was a Portainer constraint. Portainer ships
> only the compose *content* to Agent (non-local) endpoints, **not** sibling files. A relative
> `./nginx.conf` bind mount had nothing to mount on the VPS, so Docker auto-created a bogus
> directory and the deploy failed (`not a directory: Are you trying to mount a directory onto a file`).
> Komodo clones the whole repo, so a real file would now work. Turning the block into one is a
> Phase 3 follow-up PR ([§8](../runbooks/setup-operations/komodo-migration.md#phase-3--decommission)),
> not something to fold into another change.
>
> **The Komodo periphery is NOT in this stack** — it is the transport this Stack deploys through, so
> it must not be torn down by its own deploys. See [micro-vps-periphery](micro-vps-periphery.md). The
> Portainer agent and the `/home/ubuntu/` break-glass copy were removed on 2026-09-17 (SVC-2 Phase
> 3); the periphery's clone is the break-glass now.

## Host

| Field       | Value                                                         |
| ----------- | ------------------------------------------------------------- |
| Provider    | Oracle Cloud (free tier)                                      |
| Instance    | `instance-20260417-1014`, Ubuntu 24.04 LTS, 2 vCPU / 954 MiB / no swap / 45 GB |
| Public IP   | `198.51.100.10`                                              |
| VPS tailnet IP | `100.64.0.12` (tailscale native pkg, `--accept-routes`)  |
| NAS tailnet IP | `100.64.0.11` (peer `nas`; Caddy listens `0.0.0.0:80/443/8443`) |
| Docker      | 29.x + Compose v5 (docker.com apt repo); `docker` enabled at boot; point releases install automatically, majors are held |
| OS updates  | automatic every night: `unattended-upgrades` at 22:45 UTC (security, `-updates`, Docker 29.x), reboot at **23:45 UTC** when one is required — [OS updates](../runbooks/setup-operations/os-updates.md) |

## Access (SSH)

| Field    | Value                                                            |
| -------- | --------------------------------------------------------------- |
| Command  | `ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10` (repo root, after `scripts/secrets.sh unlock`) |
| User     | `ubuntu` (passwordless `sudo`; **not** in `docker` group → `sudo docker`) |
| Port     | `2222` (non-standard, key-only)                                |

## Stack

Two independently-managed pieces:

| Service           | Managed by | Where | Role |
| ----------------- | ---------- | ----- | ---- |
| `nginx`           | **Komodo Stack** `micro-vps-ingress` (Server `micro-vps`) | repo [`stacks/micro-vps-ingress/`](../../stacks/micro-vps-ingress/), cloned to `/etc/komodo/repos/nas` | `nginx:alpine`, `network_mode: host`, stream-forwards public `:80/:443` |
| `komodo-periphery` | **repo + SSH apply** | repo [`stacks/micro-vps-periphery/`](../../stacks/micro-vps-periphery/). See [micro-vps-periphery](micro-vps-periphery.md) | the transport; bound **tailnet-only** `100.64.0.12:8120` |

Both `restart: unless-stopped`. Config backups in `/home/ubuntu/backups/<ts>/`. The stream config,
abridged — the compose file is authoritative, and writes every nginx `$` as `$$`:

```nginx
stream {
    geo $cf_edge {                     # Cloudflare's published ips-v4 + ips-v6
        default          0;
        173.245.48.0/20  1;            # …the rest of the list
    }

    # "<peer is Cloudflare>:<SNI>" -> upstream. Only public names reach the NAS, and the
    # orange-clouded four only via Cloudflare.
    map "$cf_edge:$ssl_preread_server_name" $public_upstream {
        "1:auth.example.com"      100.64.0.11:8443;
        "1:files.example.com"     100.64.0.11:8443;
        "1:immich.example.com"    100.64.0.11:8443;
        "1:mealie.example.com"    100.64.0.11:8443;
        "0:jellyfin.example.com"  100.64.0.11:8443;   # gray-cloud: any source
        "1:jellyfin.example.com"  100.64.0.11:8443;
        default                     "";                    # anything else -> closed
    }
    server { listen 80;  proxy_pass 100.64.0.11:80; }   # -> NAS Caddy, over Tailscale
    # PROXY v1 -> Caddy's dedicated :8443 listener, so it sees the peer this VPS saw.
    # Plain NAS :443 stays PROXY-free for direct LAN/tailnet clients.
    server { listen 443; ssl_preread on; proxy_protocol on; proxy_pass $public_upstream; }
}
```

> **The break-glass is the periphery's clone, which a deploy keeps current.** The hand-kept copy at
> `/home/ubuntu/` had to be re-copied on every config change and once lagged behind as a
> pre-allowlist blind-forward, which would have **disabled Layer 1** mid-incident. It was removed on
> 2026-09-17, after `config --hash nginx` from the clone matched the running container.

> **New public service?** All of these, or it fails in one direction or the other:
>
> - its hostname in the `map` in
>   [`stacks/micro-vps-ingress/docker-compose.yml`](../../stacks/micro-vps-ingress/docker-compose.yml)
>   plus a `config-rev` bump — without it the site works on LAN but not
>   from the internet;
> - a Caddyfile site block for both `name.example.com` and `https://name.example.com:8443`
>   that does **not** import `lan_only` ([caddy.md](caddy.md));
> - the name in `PUBLIC_HOSTS` (and `CF_ONLY_HOSTS` or `DIRECT_PUBLIC_HOSTS`) in
>   [`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml), and in
>   [network.md](../network.md) → Access control.

## Data flow

```text
Internet client
   -> Cloudflare edge (orange-cloud names: terminates client TLS, origin-pulls to the VPS)
   -> VPS 198.51.100.10 :80/:443
        -> nginx (stream proxy, host net)
             :80  -> 100.64.0.11:80    (NAS Caddy, over Tailscale — HTTP->HTTPS redirects only)
             :443 -> 100.64.0.11:8443  (SNI + Cloudflare-peer allowlist; PROXY protocol v1)
   -> Tailscale (WireGuard) -> NAS Caddy -> auth / files / immich / jellyfin / mealie
```

nginx does raw TCP forwarding — the WireGuard tunnel is the transport. `curl https://100.64.0.11`
with **no SNI** fails the TLS handshake at Caddy (expected; real clients carry SNI). Internet-scanner
probes to `:80` with no valid Host likewise go nowhere — benign log noise.

## Public ports (VPS)

| Port  | Service            | Notes                                             |
| ----- | ------------------ | ------------------------------------------------- |
| 2222 | sshd               | admin, key-only                                   |
| 80    | nginx stream       | → NAS `100.64.0.11:80` via Tailscale           |
| 443   | nginx stream       | → NAS `100.64.0.11:8443` (Caddy's PROXY-protocol listener) via Tailscale |

`8120` (Komodo periphery) is tailnet-IP-bound, not public. `111`/rpcbind masked. Firewall =
iptables (Oracle default); **no ufw, no fail2ban**.

## Dependencies

- **Tailscale on both ends.** If the NAS tailnet node (the `tailscale` subnet-router stack) or the
  VPS's tailscaled drops, the VPS can't reach Caddy and **all public sites go down** (LAN/tailnet
  clients unaffected — they hit Caddy directly). See [tailscale.md](tailscale.md). The tailnet ACL
  must also let this node reach the NAS on `:80` **and** `:8443` — a port-scoped policy that lists
  only `:443` takes every public site down.
- Caddy on the NAS ([caddy.md](caddy.md)) is the actual reverse proxy + TLS.
- **Cloudflare DNS** — orange-cloud records for every name except `jellyfin`, whose gray-cloud `A`
  record points at `198.51.100.10`.

## Security: the tailnet-allowlist gotcha (important)

Without filtering, the VPS would forward public `:443` **blind** (raw TCP, all SNI) to the NAS.
Every connection it opens comes from the **VPS's own tailnet IP `100.64.0.12`**, which sits inside
`100.64.0.0/10` — the Tailscale CGNAT range Caddy's LAN-only `@lan` matcher **admits** so remote
tailnet devices can reach admin UIs. Anything that reaches Caddy looking like that address — a
blind-forward to `:443`, or plain `:80` — would pass as a trusted tailnet client. Net effect:
**every LAN-only admin UI (komodo, *arr, etc.) exposed to the internet.** Two independent layers
close this:

**Layer 1 — SNI allowlist on the VPS** (`ssl_preread` + `map`, see the config above): only the
public hostnames (`auth`/`files`/`immich`/`jellyfin`/`mealie`) are forwarded; any other SNI — and
no-SNI probes — gets the connection closed at the front door. A LAN-only hostname never even
reaches Caddy from the internet. Maintenance cost: a new public service needs a `map` entry here
(see the note in Stack). Plain `:80` (HTTP has no SNI) stays blind-forwarded — it only serves
HTTP→HTTPS redirects (the wildcard cert renews via DNS-01, not HTTP-01), and Layer 2 still applies
to it.

**Layer 1b — Cloudflare-only for the orange-clouded four.** `jellyfin` is gray-cloud by necessity
(streaming, ToS §2.8), so its A record publishes this VPS's address — which makes the origin public
knowledge for **every** name here. Anyone who resolves `jellyfin` could open a direct connection
with `auth`/`files`/`immich`/`mealie` in the SNI and skip Cloudflare's WAF, bot rules and managed
challenges entirely. The `map` key is therefore `"<peer-is-cloudflare>:<SNI>"`, with the first half
coming from a `geo $cf_edge` block holding Cloudflare's published `ips-v4` + `ips-v6` ranges.

> **This layer fails closed.** A stale range list is a real outage for the four names, not a
> degraded signal — the opposite of the `appsec_fail_open` tradeoff on the NAS. That is deliberate
> (a gate that fails open is not a gate), but it means the list is load-bearing: re-check
> https://www.cloudflare.com/ips-v4 and `ips-v6` when Cloudflare announces a change. The nightly
> health check diffs this list against Cloudflare's, and the A1 Kuma probes the public names every
> ~60 s, so a bad list surfaces well before the next 6-hourly probe.

Direct-to-origin access to those four is gone as a side effect, including `curl --resolve` against
the VPS IP. Reach them through Cloudflare, or from LAN/tailnet where AdGuard points the names at
the NAS.

**Layer 2 — Caddy-side exclusion:** every LAN-only vhost's `@lan` matcher excludes the VPS tailnet
IP, so anything the VPS forwards is refused while real tailnet clients still pass:

```caddyfile
@lan {
    remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10
    not remote_ip 100.64.0.12      # VPS ingress — public traffic forwarded by the VPS
}
```

Unlike NPMplus's ordered `allow`/`deny` list, the IP lists OR and the two matchers AND, so the
exclusion cannot be reordered into a hole ([caddy.md](caddy.md) → LAN-only vs public). Public hosts
(`auth`/`files`/`immich`/`jellyfin`/`mealie`) carry no `@lan` matcher and are unaffected.

Layer 2 is invisible from the internet whenever Layer 1 is healthy, so it gets its own assertion,
sent to Caddy's `:8443` listener **from this VPS** over a PROXY-protocol header — see the
[edge access policy probe runbook](../runbooks/setup-operations/edge-access-policy-probe.md).

Each layer alone covers the other's failure modes: Layer 1 protects when a vhost is written without
the `lan_only` snippet, or the VPS tailnet IP changes and the exclusion goes stale; Layer 2 protects
`:80` and anything that slips past the front door.

- **If the VPS tailnet IP ever changes**, update it in `stacks/caddy/Caddyfile` — the three
  `lan_only*` snippets **and** `proxy_protocol { allow … }` in the `:8443` server block — and
  `VPS_TAILNET_IP` in `edge-access-policy.yml`. A stale `allow` fails closed (every public site
  down); a stale `not remote_ip` fails silently open, with only Layer 1 still holding for `:443`.
- **Real client IPs are already recovered**, in two hops: the `proxy_protocol on` above hands Caddy
  the peer this VPS saw, and Caddy resolves `CF-Connecting-IP` on `:8443` to get past the Cloudflare
  edge address — see [caddy.md](caddy.md) → Real client IP behind Cloudflare. An L7 proxy here is
  not needed for that.

## Operations

Normal path (nginx): edit [`stacks/micro-vps-ingress/`](../../stacks/micro-vps-ingress/) in this repo → commit →
push. The `deploy-stacks` workflow sends Komodo `DeployStack` for this stack, which git-pulls the
periphery's clone and runs `compose up -d` on the VPS, then health-checks it. **Caveats:**

- A change to the inlined config *content* alone needs a `config-rev` label bump to actually
  recreate the container (see Common failures).
- **Every recreate takes all public sites down for ~11 s.** nginx's graceful `SIGQUIT` closes the
  listeners and then waits on open streams until Docker kills it after 10 s (plan F22). Push
  changes here when a short public outage is acceptable.

The periphery is managed by hand ([micro-vps-periphery](micro-vps-periphery.md)). SSH is the
break-glass path for nginx.

Deploy by hand (e.g. when the runner is offline): Komodo → Stacks → `micro-vps-ingress` →
**Deploy** (LAN-only UI), or dispatch `deploy-stacks` with `stacks=micro-vps-ingress`.
Then dispatch [`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml).

### Restart / redeploy nginx (break-glass, SSH)

Only when Komodo cannot deploy the Stack (Server `micro-vps` not `Ok`, or Core down). The clone at
`/etc/komodo/repos/nas` holds the last commit Komodo deployed:

```sh
ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10
cd /etc/komodo/repos/nas/stacks/micro-vps-ingress
sudo docker compose -p micro-vps-ingress up -d          # same project name, so it adopts, not duplicates
sudo docker compose -p micro-vps-ingress restart nginx  # bounce only
```

The host's compose hashes differently from the periphery's, so this recreates the container: ~11 s
of public outage (F22). **Deploy** the Stack from Komodo once it is back.

Changing the periphery's version: [micro-vps-periphery](micro-vps-periphery.md).

### Reboot survival

The host updates itself around 22:45 UTC and reboots at 23:45 UTC when an update needs it
([OS updates](../runbooks/setup-operations/os-updates.md)). A Docker update restarts nginx too. On
2026-09-16 a test reboot took public sites down for about 2 minutes, and every container returned
on its own.

`restart: unless-stopped` + `docker` enabled at boot bring the containers back. If nginx doesn't,
**Deploy** the Komodo Stack (SSH fallback above); if the periphery doesn't, see
[micro-vps-periphery](micro-vps-periphery.md).

### Common failures

- **All public sites down, LAN fine** → VPS can't reach the NAS over Tailscale. Check
  `sudo tailscale status` on the VPS (peer `nas` online?), then prove both listeners from the VPS:

  ```sh
  # the tunnel and Caddy at all (plain :443, no PROXY header) — expect 200
  curl -sk --resolve files.example.com:443:100.64.0.11 https://files.example.com -o /dev/null -w '%{http_code}\n'
  # the listener the public path really uses — expect a 2xx/3xx
  curl -sk --haproxy-protocol --resolve jellyfin.example.com:8443:100.64.0.11 \
    https://jellyfin.example.com:8443/ -o /dev/null -w '%{http_code}\n'
  ```

  The first failing means the NAS `tailscale` stack or subnet router is down; only the second
  failing points at the tailnet ACL (`:8443` not allowed) or the `:8443` publish on the `caddy`
  stack. See [cert-dns-proxy-outage runbook](../runbooks/incident-response/cert-dns-proxy-outage.md).
- **VPS rebooted, sites down** → nginx didn't relaunch: **Deploy** the Komodo Stack; break-glass above
  if Komodo cannot reach the periphery (Server `micro-vps` not `Ok`).
- **Komodo Server `micro-vps` not `Ok`** → periphery down or tailnet issue: `sudo docker ps` on the
  VPS, confirm `8120` bound to `100.64.0.12` (`sudo ss -tlnp | grep 8120`); see
  [micro-vps-periphery](micro-vps-periphery.md).
- **NAS tailnet IP changed** (rare — tailscale IPs are stable) → update every `100.64.0.11` in
  the inlined config inside [`stacks/micro-vps-ingress/docker-compose.yml`](../../stacks/micro-vps-ingress/docker-compose.yml)
  (the `map` values and the `:80` server), bump `config-rev`, and update the `NPM_HOST` default in `scripts/edge-access-probe.sh` (re-install
  the probe). Commit, and let `deploy-stacks` deploy it through Komodo.
- **A LAN-only host returns anything other than `525` from outside** → the VPS is
  **blind-forwarding** (`proxy_pass 100.64.0.11:443` with no `ssl_preread`/`map` — an old
  commit, Layer 1 not deployed), so every hostname reaches Caddy and only the
  `not remote_ip 100.64.0.12` clause (Layer 2) stops it. What you then see is whatever Caddy
  said — a `520`, since Caddy `abort`s the connection (see [caddy.md](caddy.md) → LAN-only vs
  public), or real content from a host that lost its `lan_only` snippet. **With the allowlist
  active**, an unlisted SNI instead hits `proxy_pass ""` (empty map default) → the VPS closes the
  origin connection → Cloudflare can't complete the origin TLS → **`525`** (public hosts stay
  `200`/`302`). So the healthy "blocked" signal is a Cloudflare `525`.
  [`edge-access-policy.yml`](../../.github/workflows/edge-access-policy.yml) asserts the same thing
  one hop earlier — `curl --resolve` straight at the VPS public IP, where a blocked host must have
  its connection closed before TLS (curl exit 35) — because Cloudflare serves GitHub runner IPs a
  managed challenge. Confirm and fix:

  ```sh
  # Is the live config blind-forward (bad) or does it have the map/ssl_preread (good)?
  sudo docker exec micro-vps-ingress-nginx-1 grep -E 'ssl_preread on|map .*public_upstream' /etc/nginx/nginx.conf \
    || echo 'NO SNI ALLOWLIST — blind-forward, redeploy needed'
  ```

  Fix: redeploy `stacks/micro-vps-ingress` (**Deploy** the Komodo Stack — see Operations). Verify from
  outside: an unlisted host (e.g. `npm`) should be a Cloudflare `525`, `auth`/`files`/`immich`/`jellyfin`/`mealie`
  still reachable. Diagnostic from any machine (forces the public path, bypassing LAN DNS):

  ```sh
  cf=$(nslookup -type=A kuma.example.com 1.1.1.1 | awk '/Name:/{f=1;next} f&&/Address/{print $2;exit}')
  curl -sv --resolve kuma.example.com:443:$cf https://kuma.example.com/ -o /dev/null 2>&1 | grep '< HTTP/'
  ```

- **nginx crash-loops with `[emerg] invalid number of arguments in "map" directive`** → an nginx
  `$variable` in the inlined `configs.*.content` was written with a single `$`. **Compose
  interpolates the `content:` string**, so `$ssl_preread_server_name` / `$public_upstream` are
  substituted to empty → `map  {` → nginx won't start (public ingress DOWN). Write them as `$$` in
  the compose so Compose emits a literal `$`. Check: `sudo docker exec micro-vps-ingress-nginx-1 nginx -t`.

- **Pushed a `stacks/micro-vps-ingress/` change but nothing redeployed** → two gotchas: (1) the
  `deploy-stacks` run was lost or failed. Its log shows `deploy micro-vps-ingress through Komodo`
  and the Komodo update's result. A run GitHub evicted is picked up by `reconcile-owned` at the next
  :23, without a health gate. If the runner is offline, deploy by hand (see Operations). (2) A
  change to `configs.*.content` **alone** does not always make Compose recreate the container — the
  stack's `ConfigHash` advances but the old container keeps running. The `config-rev` label on the
  `nginx` service forces the recreate; **bump it whenever the config changes**.

## Last updated

2026-09-17 — the Portainer agent and the `/home/ubuntu/` break-glass copy removed (SVC-2 Phase 3); the periphery's clone is the break-glass.

2026-09-15 — deployed by the Komodo Stack; Portainer's redeploy and webhook are the §10 rollback only
