# Service: A1 Tor WebTunnel bridge

## Overview

A Tor **WebTunnel bridge** on the Ampere A1, next to the [obfs4 bridge](a1-vps-tor-bridge.md). To a
censor it is an ordinary HTTPS site. Users connect to `https://<domain>/<secret path>`, and the matrix
stack's Caddy passes that one path through to the bridge as an HTTP upgrade. Every other path gets a
placeholder page. WebTunnel keeps working where obfs4 itself gets fingerprinted and blocked. Like the
obfs4 bridge it is **unlisted and never an exit**: it talks only to its users and to other Tor relays.

### Why this shape (assessed 2026-09-11)

| Option | Why not |
| ------ | ------- |
| Tor's image, `thetorproject/webtunnel-bridge` | **amd64 only**, and the A1 is arm64. This repo builds the same thing for arm64 and keeps it patched by itself — see [Image and security updates](#image-and-security-updates) |
| The AMD micro, where Tor's image would run | Same reason as for obfs4: 954 MiB RAM, a 50 Mbps cap, and it is the only public ingress |
| A `example.com` subdomain | The URL is part of every bridge line, and censors collect bridge lines. A separate domain used for nothing else keeps your name out of those lists |
| A port of its own instead of `:443` | WebTunnel's cover is looking like a normal website, which means `:443`, and the A1's `:443` already belongs to the matrix Caddy |

**Same IP as the obfs4 bridge.** A censor that blocks `198.51.100.20` loses both. What this adds is a
second transport, not a second address.

## Stack

- **Stack folder:** `stacks/a1-vps-webtunnel/` (the compose file and the `Dockerfile` the image is built from)
- **Compose file:** `stacks/a1-vps-webtunnel/docker-compose.yml`
- **Image:** `ghcr.io/drizzelat/webtunnel-bridge`, built by
  [`build-webtunnel-image.yml`](../../.github/workflows/build-webtunnel-image.yml). It holds the WebTunnel server built
  from Tor's source (fetched through the Go module proxy), Tor from `deb.torproject.org`, and Tor's own
  `start-tor.sh` / `get-bridge-line.sh` from the same release. The tag is the WebTunnel version.
- **Deploy:** Komodo Stack `a1-vps-webtunnel` on Server `a1-vps`, adopted 2026-09-15
  ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its folder deploys it
  through Komodo.
- **Front door:** the `caddy` service of [a1-vps-matrix](a1-vps-matrix.md), over the
  `proxy_a1-vps-webtunnel` network that stack defines.

## Access

No host port is public.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `443/tcp` | public, **matrix Caddy** | `https://<WEBTUNNEL_DOMAIN><WEBTUNNEL_PATH>` → `a1-webtunnel:15000`. Any other path gets a placeholder page |
| `15000/tcp` | `proxy_a1-vps-webtunnel` only | The WebTunnel server; Caddy reaches it by container name |
| `9444/tcp` | inside the container | ORPort, never published. Tor's WebTunnel torrc sets `AssumeReachable 1`, so no reachability test needs it |
| `9036/tcp` | `100.64.0.13` (tailnet) | `MetricsPort`, scraped by `victoriametrics` on the NAS (job `tor-webtunnel`) |

No Security List change is needed: `:80`/`:443` are already open for Matrix.

**Traffic:** Grafana → *NAS (git)* → **Tor — Bridges & Snowflake** (`tor-traffic`), split per bridge.

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/var/lib/tor` | `/opt/tor-webtunnel/data` | Bridge identity keys, and the accounting state that keeps the monthly cap correct across restarts |

> **Pre-create it owned by `101:101`, mode `0700`:**
> `sudo install -d -o 101 -g 101 -m 0700 /opt/tor-webtunnel/data`. The image runs as `debian-tor`
> (uid 101). A directory Docker creates itself is `root:root`, and Tor exits.
>
> **Not backed up**, same as the obfs4 bridge. Losing it means a new identity, and the old bridge line stops
> working for everyone who has it.

## Environment variables

These come from the vault and are applied with `scripts/secrets.sh push <stack>`. Two stacks carry them:

| Stack | Variable | Description |
| ----- | -------- | ----------- |
| `a1-vps-webtunnel` | `WEBTUNNEL_URL` | `https://<domain>/<secret path>`. **Secret**: anyone who knows the path can confirm the site is a bridge. The image refuses to start without an `https://host/path` value (exit 64) |
| `a1-vps-webtunnel` | `TOR_BRIDGE_CONTACT` | Optional `ContactInfo`, as for the obfs4 bridge |
| `a1-vps-matrix` | `WEBTUNNEL_DOMAIN` | The bridge's domain, used as Caddy's site address. If unset, it renders as `http://webtunnel.invalid`, a plain-HTTP placeholder that never attempts a certificate |
| `a1-vps-matrix` | `WEBTUNNEL_PATH` | The secret path, with its leading `/`. Must match `WEBTUNNEL_URL` exactly |

Generate the path once: `echo "/$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"`.

## Configuration

The torrc comes from Tor's `start-tor.sh`; every `WEBTUNNELV_<Option>=<value>` becomes a `<Option> <value>` line.

| torrc | Value | Why |
| ----- | ----- | --- |
| `Address` / `AddressDisableIPv6` | `198.51.100.20` / `1` | Same as obfs4: the container only sees its Docker IP. Without it Tor logs `Unable to find IPv4 address for ORPort` and has to guess from directory responses |
| `AccountingMax` / `AccountingRule` / `AccountingStart` | `1 TBytes` / `out` / `month 1 00:00` | 1 TiB of egress per calendar month (UTC). The obfs4 bridge caps its own 1 TiB, so together they stay inside the 2 TiB of Oracle's 10 TB that Tor was given. At the cap Tor hibernates until the 1st |
| `RelayBandwidthRate` / `RelayBandwidthBurst` | `5 MBytes` / `10 MBytes` | Same as obfs4: leaves Synapse its share of the uplink |
| `MaxMemInQueues` | `256 MB` | Tor sizes it from host RAM, not from the 512M container limit |
| `MetricsPort` / `MetricsPortPolicy` | `0.0.0.0:9036` / `accept 100.64.0.11,accept 172.16.0.0/12` | Same as the obfs4 bridge: a tailnet scrape arrives from the NAS IP or from the Docker gateway, depending on the host's `FORWARD` rule order ([why](a1-vps-tor-bridge.md#configuration)). The real gate is the tailnet-only publish |

**The Caddy side** is one site block in the matrix stack's inline `Caddyfile`: `handle ${WEBTUNNEL_PATH}`
→ `reverse_proxy a1-webtunnel:15000`, and a static page for everything else. Caddy forwards the upgrade
without extra directives and compresses nothing unless told to. No access log is configured, so bridge
users leave no request log on the A1.

## Domain

Any domain works, and nothing about it should look like Tor. The cheapest renewal found on 2026-09-11 is
**`.de` at about $4/year** (INWX, Dynadot, Porkbun), and a `.de` name on a Frankfurt IP looks
unremarkable too. Point an `A` record at `198.51.100.20`, **DNS-only** (no CDN proxying), so Caddy's
Let's Encrypt HTTP-01 challenge reaches the A1.

## Dependencies

- **a1-vps-matrix** — its Caddy terminates TLS and defines `proxy_a1-vps-webtunnel`, so it has to be
  deployed, network included, before this stack. `WEBTUNNEL_DOMAIN` and `WEBTUNNEL_PATH` live in its env.
- **The GHCR package `webtunnel-bridge`, set to public.** The A1 holds no registry credentials, and the
  Renovate review reads manifests anonymously. Same as `nas-caddy`.
- **Tailnet NAS → A1** for the metrics scrape; [Observability](observability.md) job `tor-webtunnel`.

## Notes

- **Unlisted is not secret.** Bridge lines hand out the domain and the URL. The path keeps casual scanners
  from telling the site apart from any other, but a censor who collects bridge lines has it anyway.
- **Egress** counts against the same Oracle pool as everything else on the tenancy. See the obfs4 bridge's notes.
- **Oracle AUP:** the same position as the obfs4 bridge.
- **Rotating the path** (if it has leaked): put a new value in both vault entries, then push `a1-vps-matrix`
  first and `a1-vps-webtunnel` second. The bridge line changes, and users of the old one lose the bridge.

## Operations

SSH: `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20`

### First deploy

This takes two merges, because the compose pins a digest that only exists after the first build.

1. **Domain.** Buy it and point an `A` record at `198.51.100.20`, DNS-only.
2. **Image.** Merge the `Dockerfile`, the workflow, the trigger script (then `webtunnel-build-trigger.sh`, now `scripts/tor-bridge-image-trigger.sh`) and the Renovate
   rules. Run `gh workflow run build-webtunnel-image.yml`; its summary prints the `image: …@sha256:…`
   line. Then GitHub → *Packages* → `webtunnel-bridge` → *Package settings* → *Change visibility* →
   **Public**. Create the trigger cron
   ([renovate-trigger → Tor bridge image trigger](../runbooks/setup-operations/renovate-trigger.md#tor-bridge-image-trigger)).
3. **Host dir** on the A1: `sudo install -d -o 101 -g 101 -m 0700 /opt/tor-webtunnel/data`.
4. **Env.** Run `scripts/secrets.sh edit a1-vps-matrix` to add `WEBTUNNEL_DOMAIN` and `WEBTUNNEL_PATH`, then
   `scripts/secrets.sh edit a1-vps-webtunnel` for `WEBTUNNEL_URL` and `TOR_BRIDGE_CONTACT`. Push the matrix
   env **now**, with `scripts/secrets.sh push a1-vps-matrix`. That follows the matrix doc's rule that env goes in before compose.
5. **Stack.** Merge the compose (pinned to the digest from step 2), the matrix Caddy change, the obfs4 cap
   split and both `.env.age` files with `[skip ci]` in the commit message. Then deploy in this order, waiting
   for each run to go green:

   ```sh
   gh workflow run deploy-stacks.yml -f stacks=a1-vps-matrix      # network + vhost
   scripts/secrets.sh push a1-vps-webtunnel                                          # creates the stack
   gh workflow run deploy-stacks.yml -f stacks="a1-vps-webtunnel a1-vps-tor-bridge"
   ```

6. **Check.** `curl -sI https://<domain>/` should answer `200` with the placeholder page, and the bridge log should show
   `Bootstrapped 100%` and the `webtunnel` transport registered.

### Bridge line, fingerprint, status

```sh
sudo docker exec a1-webtunnel get-bridge-line.sh               # webtunnel [<placeholder IPv6>]:443 <fingerprint> url=https://…
sudo cat /opt/tor-webtunnel/data/hashed-fingerprint            # for Relay Search
sudo docker logs a1-webtunnel 2>&1 | grep -iE 'bootstrapped|transport|hibernat|accounting' | tail
```

The IPv6 address in the bridge line is a placeholder that the pluggable-transport format requires; nobody
connects to it.

### Image and security updates

No step waits for a human:

| Upstream change | How it reaches the A1 |
| --------------- | --------------------- |
| Debian security fix, new Tor release | Every day at 03:40 Vienna, [`tor-bridge-image-trigger.sh`](../../scripts/tor-bridge-image-trigger.sh) dispatches the build workflow (its own `schedule:` is a late fallback). The workflow dry-runs `apt-get upgrade` inside the published image. Any pending package means a rebuild, pushed under the **same tag** with a new digest |
| New Go patch release, new `debian:trixie-slim` | Caught by the same run: the image's `nas.go-version` / `nas.base-digest` labels no longer match what a build would pull |
| New WebTunnel release, new Go minor (`golang:1.27`) | Renovate opens a PR on the `Dockerfile`, which is **automerged** (`renovate.json`). The merge triggers a build, which pushes a new tag |
| Any of the above, once pushed | Renovate's 04:15 run opens the compose PR → [renovate-pr-review](../runbooks/setup-operations/renovate-pr-review.md) (arm64 image delta + risk verdict) → the 05:20 sweep merges it → `deploy-stacks` redeploys. Identity and accounting survive in `/opt/tor-webtunnel/data` |

A Tor security release reaches the A1 by the next morning at the latest. The weekly
[`image-cve-scan`](../../.github/workflows/image-cve-scan.yml) covers the pinned image like every other.
Before pushing, a build checks `tor --version`, checks that the bridge binaries exist, and checks that an empty
`WEBTUNNEL_URL` is refused.

To run it by hand: `gh workflow run build-webtunnel-image.yml -f force=true`. A run that finds nothing to do
reports the image as current in its summary and pushes nothing.

**Where it can still stall:** a review that comes back `RISK: REVIEW` (merge that compose PR by hand), a
failed build (GitHub sends its failure email), or an automerged `Dockerfile` PR whose checks fail and leave it open.

### Restart / redeploy

Komodo → Stacks → `a1-vps-webtunnel` → **Deploy**, or push to `stacks/a1-vps-webtunnel/`.
A `Dockerfile`-only push also redeploys the unchanged compose, which is harmless.

### Upgrade

See [Image and security updates](#image-and-security-updates). Rollback = revert the compose pin and
redeploy; Tor keeps its identity across image changes.

### Restore from backup

Nothing to restore (see Volumes).

### Common failures

- **Container exits with code 64** → `WEBTUNNEL_URL` is empty or not `https://host/path`: the stack was
  created without its vault env. Run `scripts/secrets.sh push a1-vps-webtunnel`.
- **Container exits with a DataDirectory permission error** → the host dir is not `101:101`. Re-run the
  `install -d` line.
- **The site answers but the bridge path returns 502** → the bridge container is down or not on the
  network: `sudo docker network inspect proxy_a1-vps-webtunnel` must list both `matrix-caddy` and
  `a1-webtunnel`.
- **`network proxy_a1-vps-webtunnel declared as external, but could not be found`** → this stack deployed
  before the matrix stack created the network. Deploy `a1-vps-matrix`, then this stack.
- **No certificate for the domain** → the `A` record is missing, proxied, or still propagating. Caddy
  retries on its own; check `sudo docker logs matrix-caddy 2>&1 | grep -i <domain>`.
- **Image pull `denied` or `unauthorized` on the A1** → the GHCR package is still private.
- **`tor-webtunnel` target down in Grafana, container running** → same checks as for the obfs4 bridge. From the NAS, run
  `sudo docker exec victoriametrics wget -qO- http://100.64.0.13:9036/metrics`.

## Last updated

2026-09-16 — `MetricsPortPolicy` also accepts the NAS tailnet IP (see the obfs4 bridge's Configuration).

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
