# Service: A1 NTP Pool server

## Overview

A public NTP server on the Ampere A1, registered with the [NTP Pool](https://www.ntppool.org/): the
`pool.ntp.org` names that phones, routers, Linux installs and IoT devices ask for the time. The pool
assigns servers to zones by GeoIP. `198.51.100.20` is in Oracle's Frankfurt region, so expect the
`de` and `europe` zones.

Three addresses serve the pool, each registered as its own server: the IPv4 `198.51.100.20` and two
IPv6 addresses in the VNIC's `/64`, see [IPv6](#ipv6). Zones are not something a member picks, and a
server cannot be added to a second country zone; the only per-server lever is the *net speed*
setting, which is already at its maximum.

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
- **Images:** `dockurr/chrony` (Alpine, chrony with NTS support), `quay.io/superq/chrony-exporter`
  as the metrics sidecar `a1-ntp-exporter`, and `prom/node-exporter` as `a1-ntp-netstat`, which only
  reads the host's UDP counters for the IPv4/IPv6 split; all pinned in the compose file.
- **Deploy:** Komodo Stack `a1-vps-ntp` on Server `a1-vps`
  ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its folder deploys it
  through Komodo.

## Access

No UI.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `123/udp` | public, IPv4 + IPv6 | NTP. chronyd binds it directly on the host: the stack runs `network_mode: host`, see [IPv6](#ipv6). Needs four **stateless** Oracle Security List rules, see [Security List rules](#security-list-rules), **and** a host iptables `ACCEPT`, see [Host firewall](#host-firewall) |
| `80/tcp` | public, shared | Not this stack: `matrix-caddy` redirects the pool's names to `https://www.ntppool.org/`, see [Web redirect](#web-redirect) |
| `9037/tcp` | `100.64.0.13` (tailnet) | `chrony_exporter` metrics (container `:9123`), scraped by the NAS `victoriametrics` (job `ntp`) |
| `9038/tcp` | `100.64.0.13` (tailnet) | `node_exporter` UDP counters (`a1-ntp-netstat`, host network), scraped by the NAS `victoriametrics` (job `ntp-netstat`) |

chrony's command port stays on the container's own localhost. `chronyc` therefore works only through
`docker exec`, and none of chrony's query interface is reachable from outside for amplification.

**Dashboard:** Grafana → *NAS (git)* → **Community services** (`community-services`), section *NTP Pool
server*: queries received and dropped by `ratelimit`, clock offset, stratum, upstream reachability,
bandwidth plus data served, and the IPv4/IPv6 share of the queries. The overview's traffic panels
count NTP alongside the other services.

chrony counts packets, never bytes, so every byte figure on the dashboard is derived: **76 B per
packet** (48 B NTP payload + 8 UDP + 20 IPv4) and one reply out per query `ratelimit` did not drop, so
in + out = `(2 × received − dropped) × 76`. NTS is off, so
`chrony_serverstats_authenticated_ntp_packets_total` stays at 0. Since the IPv6 addresses went live the
figure is a **lower bound**: a v6 packet is 96 B (48 + 8 + 40 IPv6) and `serverstats` does not split the
count by family, so the dashboard undercounts by up to 26 % in the limit where all traffic is v6. Ethernet framing (18 B
a frame) is not counted, nor is our own polling of the upstreams. Measured 2026-09-23 over 60 s: 1 100
queries/s in and ~1 058 replies/s out, so **164 kB/s ≈ 1.3 Mbit/s** both directions — about 14 GB a day,
of which ~7 GB is egress, ~210 GB a month against the A1's 10 TB Oracle allowance.

**IPv4 vs IPv6.** `serverstats` has no family split either, so the tile *NTP queries by IP family*
takes it from the host: IPv6 = the increase of `node_netstat_Udp6_InDatagrams` (the kernel's
`Udp6InDatagrams` from `/proc/net/snmp6`), IPv4 = chrony's received count minus that. Both count a
query before `ratelimit` sees it, so the two shares add up to chrony's total. It is an approximation
in one direction only: any other UDP the host receives over v6 counts as NTP. Today that is chrony's
own upstream replies (one per source every 1024 s) and Tailscale, if it picks a v6 path to a peer —
a handful of packets a second at most, against ~1 100 queries/s. Only the IPv4 side of the host
counter (`Udp_InDatagrams`) would be worse: it also carries DNS and, usually, Tailscale. First live
reading, 2026-09-23 13:30 UTC over the preceding hour: 267 708 of 4 519 077 queries arrived over
IPv6, so **6 % v6 / 94 % v4**.

**Pool status:** `https://www.ntppool.org/scores/198.51.100.20`, and
[manage.ntppool.org](https://manage.ntppool.org/) for the account that registered it.

### Security List rules

The four NTP rules are **stateless**:

| Direction | Source / destination | Protocol | Source port | Destination port |
| --------- | -------------------- | -------- | ----------- | ---------------- |
| Ingress | source `0.0.0.0/0` | UDP | all | `123` |
| Egress | destination `0.0.0.0/0` | UDP | `123` | all |
| Ingress | source `::/0` | UDP | all | `123` |
| Egress | destination `::/0` | UDP | `123` | all |

A fifth rule, **stateful**, allows general IPv6 egress: destination `::/0`, all protocols. The default
egress rule covers `0.0.0.0/0` only, so without it nothing but an NTP reply could leave over v6 — and
the pool's ownership check needs an HTTPS request *from the address being registered*, see
[Validate an address](#validate-an-address). It costs almost no connection tracking, because only
traffic this host initiates matches it: the pool's own replies leave from `:123` and the stateless rule
wins wherever both match.

Oracle tracks every flow that matches a stateful rule, and each shape has a cap on how many flows it
tracks. Pool clients are mostly one-off addresses, so nearly every query is a new flow. From
2026-09-19 to 2026-09-21 the ingress rule was stateful. At ~750 queries/s the table was full, and
about half of all *new* flows to and from the A1 were dropped before they reached the VM, whatever
the protocol:

- chrony's polls to PTB and Cloudflare: upstream reachability fell to 0.4–0.9.
- NTP queries from the NAS: 8 of 20 reached the A1's NIC.
- TCP connects to the A1's Caddy on `:80`: 12 of 20 needed a resent SYN.

Oracle's link-local server stayed at 1.0 because it bypasses the Security List, and the pool score
stayed near 20. Once both rules were stateless, all three tests passed 20 of 20. Queries reaching
chrony rose from ~780/s to ~1 090/s, so about 30 % of pool traffic had been dropped before it arrived.

The egress rule keeps the replies untracked. Without it, a reply matches the default stateful
allow-all egress rule and is tracked anyway. When a stateless and a stateful rule both match, the
stateless one wins. chrony's own polls leave from random ports and still use the stateful egress
rule, which is fine once the table has room.

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
| `NTP_DIRECTIVES` → `clientloglimit 134217728` | 128 MB | Rate limiting only applies to clients in the client log, at 128 B a record. The default 524 kB tracks about 4 096 addresses. 16 MB (131 072) was too few: at ~1 100 queries/s the log evicted 432 records/s, a full turnover every 5 minutes, so any client polling slower than that arrived as new and was never rate limited. 128 MB is about 1 000 000 addresses, over half an hour of unique clients |
| `network_mode: host` | chronyd binds `123/udp` on the host | Docker has no IPv6 enabled, so a published `[::]:123` is served by `docker-proxy` in userland, which rewrites every v6 client's source address to the bridge gateway. Measured before the switch: two probes from two different v6 addresses both arrived as `172.25.0.1`, one `ratelimit` bucket for the whole internet. Host networking also drops the DNAT hop for v4 |
| `-x` (entrypoint default) | no clock control | No `SYS_TIME` capability; the host clock is not this container's business |
| `cap_add` | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `NET_BIND_SERVICE` | The entrypoint runs as root, fixes the ownership of `/run/chrony`, then starts `chronyd`, which binds `:123` and drops to the `chrony` user. Measured on the A1: the running daemon keeps only `NET_BIND_SERVICE` (`CapEff 0x400`) |
| Exporter over the **socket**, not UDP 323 | `--chrony.address=unix:///run/chrony/chronyd.sock` | `serverstats` (packets served and dropped) is refused over UDP with `501 Not authorised`, even from localhost. Measured on the A1, 2026-09-14 |
| Exporter `user: "100:101"` | `chrony:chrony` in the chrony image | `/run/chrony` is `0750 chrony:chrony`, and chronyd must be able to write its reply into the exporter's client socket there |
| Exporter collectors | `tracking` (default), `serverstats`, `sources`, `--no-collector.dns-lookups` | Not `clients`: it would label every pool client's IP address |
| `a1-ntp-netstat` | `network_mode: host`, `--collector.disable-defaults --collector.netstat`, fields `^Udp6?_InDatagrams$` | `/proc/net/snmp6` belongs to the reader's network namespace, so only a host-network container sees the host's counters. Everything else in `node_exporter` is off; Beszel already covers the host. Listens on the tailnet IP itself (`--web.listen-address`), since host networking has no port publish; if `tailscale0` is not up yet it exits and `restart:` retries |

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

### Host firewall

Host networking changed which chain the traffic meets. A published port is DNATed by Docker and
traverses `FORWARD`, so `INPUT` never sees it; chronyd binding `123/udp` on the host puts every query
through `INPUT`, which on Oracle's Ubuntu image ends in `REJECT --reject-with icmp-host-prohibited`.
IPv4 NTP went dead the moment the stack was redeployed, while IPv6 kept working — the `ip6tables`
`INPUT` chain is policy `ACCEPT` with no `REJECT` of its own.

```sh
sudo iptables -I INPUT 8 -p udp --dport 123 -j ACCEPT
```

Persisted by hand in `/etc/iptables/rules.v4`, one line above the final `REJECT`, rather than with
`netfilter-persistent save`: the live table holds Docker's generated chains, and saving would freeze a
copy of them into the file. Backup at `/etc/iptables/rules.v4.bak-20260923`; check with
`sudo iptables-restore --test /etc/iptables/rules.v4`.

Nothing is needed for IPv6 today, but a `REJECT` added to the `ip6tables` `INPUT` chain later would
silently kill the two v6 servers.

### IPv6

The VCN had no IPv6 at all until 2026-09-23. It is four layers in the Oracle console, each invisible
until the one above it exists:

| Layer | Value |
| ----- | ----- |
| VCN prefix | `2001:db8:1::/56`, Oracle-allocated |
| Subnet prefix | `2001:db8:1::/64`. The dialog takes **two hex characters** that subdivide the `/56`; it rejected `00` as *Invalid input*, so the subnet is `7e` |
| Route rule | `::/0` → the VCN's Internet Gateway, in the subnet's route table |
| VNIC addresses | `2001:db8:1::20` and `2001:db8:1::21`, both Oracle-allocated on the primary VNIC |

The addresses are static on the host, in `/etc/netplan/60-ipv6.yaml` — a file of its own, because
cloud-init owns `50-cloud-init.yaml` and rewrites it. `accept-ra: true` is what supplies the default
route (`via fe80::200:17ff:fe90:a7a2`, `proto ra`); no DHCPv6 client is needed.

```yaml
network:
  version: 2
  ethernets:
    enp0s6:
      accept-ra: true
      addresses:
        - "2001:db8:1::20/64"
        - "2001:db8:1::21/64"
```

**Open item:** no ICMPv6 ingress rule. `ping6` from outside times out, which also means Packet Too
Big cannot reach the host. It does not affect NTP — a v6 reply is 96 B against a 1280 B minimum MTU —
but any future v6 service on this host will need the rule.

## Dependencies

- **Two stateless Oracle Security List rules** for `123/udp` (console actions, see
  [Security List rules](#security-list-rules)).
- **An NTP Pool account** that holds the server registration — one entry per address, three in total.
- Outbound UDP 123 to the upstreams; Oracle's default egress allows it.

## Notes

- **Joining is a long-term commitment.** The pool says so itself: after a server leaves, traffic
  takes *weeks, months or even years* to fade, because devices keep resolved addresses.
  `198.51.100.20` is also the Matrix and bridge address; if it is ever released, whoever gets it
  next inherits the NTP traffic.
- **Bandwidth is small, and the *net speed* setting is not a bandwidth promise.** It is the weight the
  pool's DNS gives this server against the others in its zones, so the traffic it produces is capped by
  what the zones generate, not by the number. At the maximum setting this server draws ~1.3 Mbit/s —
  three orders of magnitude below the figure in the form. The pool's own guidance of 5–15 packets/s for
  a typical server is well below what these zones actually deliver here.
- **The pool's scoring is the monitor.** Its monitors check the server continuously. Below a score of 10
  it drops out of DNS on its own, and it comes back when the score recovers.
- **`alpine:edge` base.** The image is built on Alpine's rolling branch. Renovate follows its `4.x` tags.

**Container logs** are capped at 10 MB × 3 files per container (`x-logging` in the compose file):
Docker's `json-file` default never rotates. Enforced by
[`compose-policy.py`](../../.github/scripts/compose-policy.py).

## Operations

SSH: `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20`

### Join the pool (once)

1. Oracle console → the A1's subnet → Security List:
   - **Add ingress rule**: tick **Stateless**, source `0.0.0.0/0`, protocol UDP, destination port `123`.
   - **Add egress rule**: tick **Stateless**, destination `0.0.0.0/0`, protocol UDP, source port `123`.

   A stateful ingress rule works at first and fails once the pool sends real load, see
   [Security List rules](#security-list-rules).
2. Deploy the stack. It has no env, so the push that lands `stacks/a1-vps-ntp/` creates it.
3. Query it from outside the A1; the NAS works:

   ```sh
   sudo docker run --rm --entrypoint chronyd dockurr/chrony:4.9 -Q -t 10 "server 198.51.100.20 iburst maxsamples 2"
   ```

   `System clock wrong by … (ignored)` means it answered. `Timeout reached` means the rules are missing.
4. [manage.ntppool.org](https://manage.ntppool.org/) → sign in → add the address, then prove ownership,
   see [Validate an address](#validate-an-address). Start at the **lowest net speed** while the server is
   unproven: the pool holds it out of DNS until the score passes 10, usually within a day, and a small
   zone — every IPv6 zone is one — would otherwise hand a large share to an untested server. Raise it to
   the maximum once the score sits at 20; the resulting traffic is nowhere near any link or budget limit.

### Validate an address

The pool proves ownership by asking for an HTTP request from the address itself. On the manage page
each unverified server shows its own *Verify* page; run the request on the A1, then open the URL it
prints in a browser signed in to the pool account:

```sh
curl --interface <the v6 address> https://validate6.ntppool.dev/p/   # validate.ntppool.dev for IPv4
```

`--interface` takes the address, not the device, so each of the two v6 servers is verified separately.
A timeout here means the stateful `::/0` egress rule is missing, see
[Security List rules](#security-list-rules).

### Status

```sh
sudo docker exec a1-ntp chronyc -n sources      # ^* marks the selected upstream
sudo docker exec a1-ntp chronyc -n tracking     # stratum, offset
sudo docker exec a1-ntp chronyc serverstats     # NTP packets received, and dropped by ratelimit
```

### Leave the pool

Delete the server on the manage page. Keep the stack running for months while traffic fades, then remove
the stack and both Security List rules.

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
- **`Client log records dropped` climbing in `chronyc serverstats`** → the client log is full and evicting.
  `chronyc -n clients | wc -l` at the record ceiling (`clientloglimit` ÷ 128 B) confirms it. `ratelimit`
  still fails open, so the score is unaffected, but repeat abusers are no longer recognised. Raise
  `clientloglimit`, and the container's `memory:` limit with it.
- **IPv4 times out while IPv6 answers** (`Timeout reached` from the `chronyd -Q` check, pool score
  falling for the v4 server only) → the host iptables `ACCEPT` for `udp/123` is gone, so `INPUT` rejects
  it. `sudo iptables -L INPUT -n --line-numbers` and see [Host firewall](#host-firewall).
- **Every v6 query logged from one address, `ratelimit` dropping nearly all of them** → the stack lost
  `network_mode: host` and is publishing the port again. Check with `chronyc -n clients | grep 172.`:
  the bridge gateway must not appear.
- **IP-family tile shows *No data*, or IPv6 stuck at 0 %** → the `ntp-netstat` target is down:
  `a1-ntp-netstat` logs `bind: cannot assign requested address` while Tailscale is not up, and recovers
  on the next restart. Right after the first deploy the IPv6 share reads low until the selected range
  no longer reaches back before the exporter started.
- **`ntp` target up but `chrony_up 0`** → the exporter cannot use the socket: `a1-ntp-exporter` logs
  `permission denied` (its `user:` no longer matches the chrony image's `chrony` uid/gid; check with
  `sudo docker exec a1-ntp id chrony`), or `a1-ntp` is down.
- **Pool score falls while `chronyc -n sources` looks healthy** → inbound UDP 123 is blocked: the
  Security List rule.
- **`chronyc -n sources` lists only `?` rows** → outbound UDP 123 or DNS for the upstream names is
  failing on the A1 (see the MagicDNS note in [a1-vps-matrix.md](a1-vps-matrix.md)).
- **Upstream reachability drops for every source except `169.254.169.254`, and new connections to the
  A1 are slow** → a `123/udp` rule is stateful again and Oracle's connection tracking is full, see
  [Security List rules](#security-list-rules). Test with new flows from the NAS; a connect time
  of 1, 2 or 3 s instead of ~12 ms means SYNs were dropped:

  ```sh
  for i in $(seq 20); do curl -so /dev/null -w '%{time_connect}\n' -H 'Host: 0.de.pool.ntp.org' http://198.51.100.20/; sleep 1; done
  ```

  Don't judge a fix by the reachability panel. Each upstream is polled every 1024 s and the ratio
  covers the last 8 polls, so it takes about 2.5 h to recover.
