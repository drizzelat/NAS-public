# Service: Snowflake proxy

## Overview

A Tor [Snowflake](https://snowflake.torproject.org/) proxy on the NAS. Censored Tor users reach a
Snowflake bridge through it over WebRTC. It is **outbound-only** (no port forward), which is the
only kind of Tor contribution the NAS can make behind CGNAT. It forwards client traffic only to
Tor's Snowflake bridge, never to arbitrary destinations, and has no access to NAS data: no volumes,
read-only root filesystem, unprivileged user.

Why only this on the NAS: a relay or obfs4 bridge needs an inbound port, and an exit relay on the
host that holds every photo and document is ruled out. The full assessment is in
[a1-vps-tor-bridge.md](a1-vps-tor-bridge.md#why-this-shape-assessed-2026-09-11); the A1 runs the
bridge half.

## Stack

- **Stack folder:** `stacks/snowflake/`
- **Compose file:** `stacks/snowflake/docker-compose.yml`
- **Deploy:** Komodo Stack `snowflake` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.
- **Image:** `thetorproject/snowflake-proxy`, the Tor Project's own.

## Access

No UI.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `9999/tcp` | `192.168.178.111` | Prometheus metrics at `/internal/metrics`, scraped by `victoriametrics` |
| UDP, ephemeral | host | WebRTC to clients, opened outbound through the NAT |

**Traffic:** Grafana → *NAS (git)* → **Tor — Bridge & Snowflake** (`tor-traffic`).

## Volumes / data

None. The proxy keeps no state.

## Environment variables

None. All settings are flags in the compose `command:`.

## Configuration

| Setting | Value | Why |
| ------- | ----- | --- |
| `network_mode` | `host` | WebRTC NAT traversal already has CGNAT in the way; a Docker NAT on top only makes it worse |
| `-capacity` | unset (no limit) | Any value deadlocks the proxy within about an hour (see [Common failures](#common-failures)). Behind CGNAT it tests `restricted` and gets about 1–2 clients an hour, so the cap was not doing anything useful |
| `-metrics-address` | `192.168.178.111` | The default `localhost` is unreachable from `victoriametrics` on its bridge network |
| `user` / `read_only` / `cap_drop` | `65534:65534` / `true` / `ALL` | The image defaults to root; the proxy needs no privileges and writes nothing |

## Dependencies

- Outbound HTTPS to the Snowflake broker and bridge; UDP to clients.
- [Observability](observability.md) scrapes it (job `snowflake`).

## Notes

- **NAT type.** Behind CGNAT the proxy will likely test as `restricted`. It then serves only clients
  whose own NAT is permissive: fewer clients, not broken. It retests every 24 h
  (`-nat-retest-interval`).
- **Exposure.** The home IP is not published anywhere. The broker and the clients it serves see it.
- **Bandwidth.** The proxy has no bandwidth limit, and `-capacity` cannot be used (see Configuration).
  *Snowflake traffic per day* on the dashboard shows what it costs. If remote streaming suffers, lower
  [Conduit](conduit.md)'s `--bandwidth` first, which uploads through the same line, then stop this stack.
- **Metric units lie.** `tor_snowflake_proxy_traffic_{inbound,outbound}_bytes_total` count **KB**
  (bytes / 1000; the help text says so), so every dashboard query multiplies by 1000.
  `tor_snowflake_proxy_connections_total` carries a `country` label.
- **Traffic counters move once an hour.** The proxy adds to both traffic counters only when it logs
  its hourly summary; the jump equals the `Traffic Relayed` figures in that log line. A
  `rate(...[$__rate_interval])` window turns each jump into a spike with zeros in between, and reads
  zero everywhere once the step is 15 min or more. Throughput panels use `rate(...[1h])`: the hourly
  average, up to an hour late. After a restart it reads zero until the first summary.
  `connections_total` counts each client as it arrives, so it needs no such window.

## Operations

> Restart/redeploy go through **Komodo** (Stack `snowflake`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

Komodo → Stacks → `snowflake` → **Restart** or **Deploy**, or push to `stacks/snowflake/` (the runner deploys it
through Komodo).

### Logs

Komodo → Stacks → `snowflake` → the service's **Log** (or `sudo docker logs snowflake-proxy`). The proxy prints its NAT type at start and a
connection/traffic summary every hour.

### Upgrade

Renovate raises the `tag@sha256` pin. Stateless: rollback = revert the pin and redeploy.

### Restore from backup

Nothing to restore.

### Common failures

- **Crash loop with a bind error on `192.168.178.111:9999`** → the NAS LAN IP changed. Update
  `-metrics-address` here and the target in `stacks/observability/victoriametrics/scrape.yml`.
- **`snowflake` target down, container running** → check
  `curl http://192.168.178.111:9999/internal/metrics` from the LAN. The path is `/internal/metrics`,
  not `/metrics`.
- **No new clients for hours or days, while the container shows `Up` and the log shows no errors** →
  the proxy has deadlocked and stopped polling the broker. It happens only when `-capacity` is set.
  On the 2.14 image with `-capacity=20` it took no clients from 2026-09-11 to 2026-09-14, and after
  each restart it deadlocked again within about an hour. The hourly summary lines keep printing and
  the metrics target stays up. Three signs give it away:
  - `go_goroutines{job="snowflake"}` sits flat at about 9–11 with no traffic.
  - `tor_snowflake_proxy_connection_timeouts_total` is at least 1.
  - The process has no connection to the broker. Run
    `sudo ss -tanp | grep "pid=$(sudo docker inspect -f '{{.State.Pid}}' snowflake-proxy),"`.
    A healthy proxy holds an `ESTAB` socket to the broker on `:443`. A deadlocked one shows only
    `:9999`.

  **Cause** (dump from 2026-09-14, checked against the source on 2026-09-15). The dump showed the
  main loop blocked in `tokens_t.ret` (`proxy/lib/tokens.go:38`). When a client does not open its
  data channel within 20 s, `runSession` gives its slot back. If the client connects anyway,
  `datachannelHandler` gives the same slot back again on exit. With a capacity set, giving a slot
  back waits for one to be in use, so the extra return blocks forever. Without a capacity it does
  nothing, so the fix is to leave `-capacity` unset. The Debian package source
  (`sources.debian.org/src/snowflake/`) is readable when gitlab.torproject.org blocks bots.
  Without `-capacity`, one run lasted 18.7 h through 270 timeouts and never stopped taking clients,
  so the daily restart cron that covered for the deadlock was removed on 2026-09-16.

  Nothing alerts on this; the sign is *Snowflake clients per hour* dropping to 0.
  If it recurs anyway: a restart clears it. For an upstream report, run `sudo kill -QUIT <pid>`
  instead: Go writes every goroutine's stack to the container log and exits, and the restart policy
  brings the container back.

## Last updated

2026-09-16 — removed the daily restart cron and `scripts/snowflake-restart.sh`; the deadlock is gone without `-capacity`.

2026-09-16
