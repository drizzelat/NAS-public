# Service: A1 NTP Pool server

## Overview

A public NTP server on the Ampere A1, registered with the [NTP Pool](https://www.ntppool.org/): the
`pool.ntp.org` names that phones, routers, Linux installs and IoT devices ask for the time. The pool
assigns servers to zones by GeoIP. `198.51.100.20` is in Oracle's Frankfurt region, so expect the
`de` and `europe` zones.

The server is `chronyd` in a container, run with **`-x`**. It measures and serves time but never adjusts the
A1's clock, which stays with `systemd-timesyncd` and Oracle's link-local server. It was tested on the A1 with
this exact image and configuration before the stack existed (2026-09-11). It synchronised within seconds,
0.1 ms from its selected source, with the PTB stratum-1 servers within about 1 ms. A client query
through the published port got an answer.

### Why this shape (assessed 2026-09-11)

| Option | Why not |
| ------ | ------- |
| chrony on the host, replacing timesyncd | Works, but it is host config outside git and outside the Komodo/Renovate path every other A1 service takes |
| `cturra/ntp` | Only a `latest` tag, and its generated config has no rate limiting |
| `dockurr/chrony` | **Chosen**: versioned tags Renovate can follow, arm64, `ratelimit` configurable |
| The NAS | No public address behind CGNAT; the pool needs a static IP |

## Stack

- **Stack folder:** `stacks/a1-vps-ntp/`
- **Compose file:** `stacks/a1-vps-ntp/docker-compose.yml`
- **Images:** `dockurr/chrony` (Alpine, chrony with NTS support), and `quay.io/superq/chrony-exporter`
  as the metrics sidecar `a1-ntp-exporter`; both pinned in the compose file.
- **Deploy:** Komodo Stack `a1-vps-ntp` on Server `a1-vps`, adopted 2026-09-15
  ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its folder deploys it
  through Komodo.

## Access

No UI.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `123/udp` | public | NTP. Needs an **Oracle Security List** ingress rule (UDP, source `0.0.0.0/0`). Host iptables needs none: Docker DNATs published ports before the `INPUT` chain's final `REJECT` |
| `80/tcp` | public, shared | Not this stack: `matrix-caddy` redirects the pool's names to `https://www.ntppool.org/`, see [Web redirect](#web-redirect) |
| `9037/tcp` | `100.64.0.13` (tailnet) | `chrony_exporter` metrics (container `:9123`), scraped by the NAS `victoriametrics` (job `ntp`) |

chrony's command port stays on the container's own localhost. `chronyc` therefore works only through
`docker exec`, and none of chrony's query interface is reachable from outside for amplification.

**Dashboard:** Grafana → *NAS (git)* → **Community services** (`community-services`), section *NTP Pool
server*: queries received and dropped by `ratelimit`, clock offset, stratum, upstream reachability, and
bandwidth plus data served. The overview's traffic panels count NTP alongside the other services.

chrony counts packets, never bytes, so every byte figure on the dashboard is derived: **76 B per
packet** (48 B NTP payload + 8 UDP + 20 IPv4) and one reply out per query `ratelimit` did not drop, so
in + out = `(2 × received − dropped) × 76`. The payload never varies here — no IPv6 on `123/udp`, and
NTS is off, so `chrony_serverstats_authenticated_ntp_packets_total` stays at 0. Ethernet framing (18 B
a frame) is not counted, nor is our own polling of the upstreams. At pool load that works out around
1.2 GB a day both directions, of which ~0.6 GB is egress against the A1's Oracle budget.

**Pool status:** `https://www.ntppool.org/scores/198.51.100.20`, and
[manage.ntppool.org](https://manage.ntppool.org/) for the account that registered it.

## Volumes / data

| Volume | Mounted at | Purpose |
| ------ | ---------- | ------- |
| `chrony-run` (named) | `/run/chrony` in both containers | chronyd's command socket, shared with the exporter |

The drift file lives in an anonymous volume, and losing it costs a few minutes of re-convergence.

## Environment variables

None, and nothing in the vault. Everything is in the compose `environment:`.

## Configuration

| Setting | Value | Why |
| ------- | ----- | --- |
| `NTP_SERVERS` | `169.254.169.254`, `ptbtime1`–`3.ptb.de`, `time.cloudflare.com` | The pool's rule: fixed, reputable upstreams, **never `pool.ntp.org` itself**. Oracle's link-local server is closest. Three PTB stratum-1 servers and Cloudflare let chrony outvote one that goes wrong |
| `NTP_DIRECTIVES` → `ratelimit` | chrony defaults (interval 3, burst 8, leak 2) | A client polling faster than about once every 8 s has most of its replies dropped. Pool monitors and well-behaved clients poll far less often |
| `NTP_DIRECTIVES` → `clientloglimit 16777216` | 16 MB | Rate limiting only applies to clients in the client log. The default 524 kB tracks about 4 096 addresses, too few for pool traffic; 16 MB is roughly 130 000 |
| `-x` (entrypoint default) | no clock control | No `SYS_TIME` capability; the host clock is not this container's business |
| `cap_add` | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `NET_BIND_SERVICE` | The entrypoint runs as root, fixes the ownership of `/run/chrony`, then starts `chronyd`, which binds `:123` and drops to the `chrony` user. Measured on the A1: the running daemon keeps only `NET_BIND_SERVICE` (`CapEff 0x400`) |
| Exporter over the **socket**, not UDP 323 | `--chrony.address=unix:///run/chrony/chronyd.sock` | `serverstats` (packets served and dropped) is refused over UDP with `501 Not authorised`, even from localhost. Measured on the A1, 2026-09-14 |
| Exporter `user: "100:101"` | `chrony:chrony` in the chrony image | `/run/chrony` is `0750 chrony:chrony`, and chronyd must be able to write its reply into the exporter's client socket there |
| Exporter collectors | `tracking` (default), `serverstats`, `sources`, `--no-collector.dns-lookups` | Not `clients`: it would label every pool client's IP address |

### Web redirect

The pool asks members that run a web server to redirect port 80 to the project page: people type
`pool.ntp.org` into a browser and get whichever member DNS handed out. Before this, the A1's Caddy
sent them to `https://pool.ntp.org/` on its own address, which has no certificate, so they saw a TLS error.

The site block lives in the `Caddyfile` of [a1-vps-matrix](a1-vps-matrix.md), which owns `:80`/`:443`:

| Detail | Why |
| ------ | --- |
| `http://` addresses | Without the scheme Caddy would try, and fail forever, to get certificates for the pool's names. HTTPS for them keeps failing the handshake; the pool asks for port 80 only |
| `*.*.pool.ntp.org` as well as `*.pool.ntp.org` | A Caddy `*` matches exactly one label; `0.de.pool.ntp.org` and `2.debian.pool.ntp.org` have two |
| `redir … permanent` | `301` to `https://www.ntppool.org/`, like Apache's `Redirect permanent` in the pool's example. Verified after deploy |

Check: `curl -sI -H 'Host: 0.de.pool.ntp.org' http://198.51.100.20/` → `301`, `Location: https://www.ntppool.org/`.

## Dependencies

- **Oracle Security List** rule for `123/udp` (a console action).
- **An NTP Pool account** that holds the server registration.
- Outbound UDP 123 to the upstreams; Oracle's default egress allows it.

## Notes

- **Joining is a long-term commitment.** The pool says so itself: after a server leaves, traffic
  takes *weeks, months or even years* to fade, because devices keep resolved addresses.
  `198.51.100.20` is also the Matrix and bridge address; if it is ever released, whoever gets it
  next inherits the NTP traffic.
- **Bandwidth is small.** By the pool's own figures a server typically sees 5–15 packets/s with daily spikes, about
  10–15 kbit/s. That is well under 5 GB a month, and the *net speed* setting on the manage page scales it.
- **The pool's scoring is the monitor.** Its monitors check the server continuously. Below a score of 10
  it drops out of DNS on its own, and it comes back when the score recovers.
- **`alpine:edge` base.** The image is built on Alpine's rolling branch. Renovate follows its `4.x` tags.

## Operations

SSH: `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20`

### Join the pool (once)

1. Oracle console → the A1's subnet → Security List → **Add ingress rule**: stateful, source
   `0.0.0.0/0`, protocol UDP, destination port `123`.
2. Deploy the stack. It has no env, so the push that lands `stacks/a1-vps-ntp/` creates it.
3. Query it from outside the A1; the NAS works:

   ```sh
   sudo docker run --rm --entrypoint chronyd dockurr/chrony:4.9 -Q -t 10 "server 198.51.100.20 iburst maxsamples 2"
   ```

   `System clock wrong by … (ignored)` means it answered. `Timeout reached` means the rule is missing.
4. [manage.ntppool.org](https://manage.ntppool.org/) → sign in → add the server `198.51.100.20` with the
   **lowest net speed**. The pool starts handing it out once the score passes 10, usually within a day.
   Raise the net speed in steps after that.

### Status

```sh
sudo docker exec a1-ntp chronyc -n sources      # ^* marks the selected upstream
sudo docker exec a1-ntp chronyc -n tracking     # stratum, offset
sudo docker exec a1-ntp chronyc serverstats     # NTP packets received, and dropped by ratelimit
```

### Leave the pool

Delete the server on the manage page. Keep the stack running for months while traffic fades, then remove
the stack and the Security List rule.

### Restart / redeploy

Komodo → Stacks → `a1-vps-ntp` → **Deploy**, or push to `stacks/a1-vps-ntp/`. A restart is
a few seconds of silence, which the score barely notices.

### Upgrade

Renovate raises the `tag@sha256` pin. Stateless: rollback = revert the pin and redeploy.

### Restore from backup

Nothing to restore.

### Common failures

- **Exits at start with `chmod: /run/chrony: Operation not permitted`** → `FOWNER` is missing from
  `cap_add`.
- **Exits with `rm: can't stat '/run/chrony/chronyd.pid': Permission denied`** → `DAC_OVERRIDE` is
  missing.
- **`ntp` target up but `chrony_up 0`** → the exporter cannot use the socket: `a1-ntp-exporter` logs
  `permission denied` (its `user:` no longer matches the chrony image's `chrony` uid/gid; check with
  `sudo docker exec a1-ntp id chrony`), or `a1-ntp` is down.
- **Pool score falls while `chronyc -n sources` looks healthy** → inbound UDP 123 is blocked: the
  Security List rule.
- **`chronyc -n sources` lists only `?` rows** → outbound UDP 123 or DNS for the upstream names is
  failing on the A1 (see the MagicDNS note in [a1-vps-matrix.md](a1-vps-matrix.md)).

## Last updated

2026-09-17 — port-80 redirect of the pool's names to `https://www.ntppool.org/`, in the A1 Caddy.

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, restart from Komodo.

2026-09-14
