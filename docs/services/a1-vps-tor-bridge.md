# Service: A1 Tor bridge (obfs4)

## Overview

A Tor **obfs4 bridge** on the Ampere A1: an unlisted entry point that lets people on censored
networks reach Tor. It is a **bridge, not a public relay, and never an exit**. Nothing leaves the
A1 on behalf of Tor users; the bridge only talks obfs4 to its users and TLS to other Tor relays, so
there is no path from Tor into the tailnet.

A [WebTunnel bridge](a1-vps-webtunnel.md) runs next to it on the same host, and the NAS half is a
[Snowflake proxy](snowflake.md). All three feed the Grafana dashboard **Tor — Bridges & Snowflake**.

### Why this shape (assessed 2026-09-11)

| Option | Why not |
| ------ | ------- |
| Exit relay, any host | Abuse complaints and police inquiries go to the operator. In the Austrian Weber case (Graz, 2012 raid) every computer in the home was seized even though running an exit is legal there. On the NAS that would mean the photo and document archive in police hands. An exit on a tailnet node could also reach tailnet services, which Caddy's LAN-only vhosts trust (`100.64.0.0/10`). |
| Public non-exit relay on the A1 | Puts `198.51.100.20` on the public relay list. Some blocklists include every relay, which would hit Matrix clients and federation on the same IP. A bridge is not in the public list. |
| Anything on the AMD micro | 954 MiB RAM, no swap, 50 Mbps internet cap, shared with the only public ingress. An OOM kill there takes every public site down. |
| Relay or bridge on the NAS | Impossible behind CGNAT (no inbound port), so the NAS runs [Snowflake](snowflake.md) instead. |

## Stack

- **Stack folder:** `stacks/a1-vps-tor-bridge/`
- **Compose file:** `stacks/a1-vps-tor-bridge/docker-compose.yml`
- **Image:** `ghcr.io/drizzelat/obfs4-bridge`, built in this repo from `stacks/a1-vps-tor-bridge/Dockerfile`
  (see [Image and security updates](#image-and-security-updates)); until 2026-09-16 it was Tor's
  `thetorproject/obfs4-bridge`. Tor's own `start-tor.sh` renders `torrc` from env; every
  `OBFS4V_<Option>=<value>` becomes a `<Option> <value>` line.
- **Deploy:** Komodo Stack `a1-vps-tor-bridge` on Server `a1-vps`, adopted 2026-09-15
  ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its folder deploys it
  through Komodo.
- **Runs on:** the Ampere A1 ([host + SSH details](a1-vps-matrix.md)), next to Matrix and the
  [Kuma watchdog](a1-vps-kuma.md).

## Access

No UI.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `4443/tcp` | public | obfs4, what bridge users connect to |
| `9443/tcp` | public | ORPort. Tor's reachability self-test needs it before the bridge is handed out |
| `9035/tcp` | `100.64.0.13` (tailnet) | `MetricsPort`, scraped by `victoriametrics` on the NAS. Reachable only over the tailnet; Configuration explains why the policy cannot name the NAS |

Both public ports need an **Oracle Security List** ingress rule (TCP, source `0.0.0.0/0`). Host
iptables needs no rule: Docker DNATs published ports in `PREROUTING`, so the packets are forwarded
to the container and never hit the `INPUT` chain's final `REJECT`.

**Traffic:** Grafana → *NAS (git)* → **Tor — Bridges & Snowflake** (`tor-traffic`). Tor's own view
is [Relay Search](https://metrics.torproject.org/rs.html) with the **hashed** fingerprint (see
Operations), about three hours after first start.

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/var/lib/tor` | `/opt/tor-bridge/data` | Bridge identity keys, `pt_state/obfs4_bridgeline.txt`, and the accounting state that keeps the monthly cap correct across restarts |

> **Pre-create it owned by `101:101`, mode `0700`:**
> `sudo install -d -o 101 -g 101 -m 0700 /opt/tor-bridge/data`. The image runs as `debian-tor`
> (uid 101; on the host that uid is `messagebus`, which is harmless). A path Docker creates itself is
> `root:root`, and Tor exits because it cannot write its DataDirectory.
>
> **Not backed up.** Losing it means a new identity and a new bridge line, and anyone using the old
> line loses the bridge. Nothing else depends on it.

## Environment variables

From the vault (`secrets.enc/portainer-env/a1-vps-tor-bridge.env.age`), written into Komodo Variables
and deployed with `scripts/secrets.sh push a1-vps-tor-bridge`. The stack deploys fine without any.

| Variable | Description |
| -------- | ----------- |
| `TOR_BRIDGE_CONTACT` | Optional. Becomes `ContactInfo`. **Public:** Relay Search shows it, so it is stored obfuscated (`email:user[]example.org`, Tor's ContactInfo format). Empty works, but Tor warns that relays without contact info may be rejected |

## Configuration

All torrc settings live in the compose `environment:` block.

| torrc | Value | Why |
| ----- | ----- | --- |
| `Address` | `198.51.100.20` | The container only sees its Docker IP; Oracle NATs the public one |
| `AddressDisableIPv6` | `1` | IPv4-only bridge; the Docker network here has no IPv6 |
| `AccountingMax` / `AccountingRule` / `AccountingStart` | `1 TBytes` / `out` / `month 1 00:00` | Caps **egress** at 1 TiB per calendar month (UTC), which is what Oracle bills. The [WebTunnel bridge](a1-vps-webtunnel.md) caps its own 1 TiB, so the two stay inside 2 TiB. At the cap Tor hibernates until the 1st |
| `RelayBandwidthRate` / `RelayBandwidthBurst` | `5 MBytes` / `10 MBytes` | Leaves Synapse its share of the uplink |
| `MaxMemInQueues` | `256 MB` | Tor sizes it from host RAM (about 4.7 GB on the A1), not the 512M container limit. Without it, memory pressure ends in an OOM kill instead of Tor trimming its own queues |
| `MetricsPort` / `MetricsPortPolicy` | `0.0.0.0:9035` / `accept 100.64.0.11,accept 172.16.0.0/12` | A scrape from the NAS reaches Tor from one of two sources, depending on the host's `FORWARD` chain (below): the NAS tailnet IP `100.64.0.11`, or the bridge gateway (`172.24.0.1` at first deploy) when Tailscale masquerades it. The policy accepts both. The real gate is the tailnet-only publish plus the tailnet ACL |

> **Why the metrics source changes between boots.** Tailscale marks traffic from `tailscale0` in its
> `ts-forward` chain, and `ts-postrouting` masquerades marked packets to the outgoing interface's
> address, which is the Docker gateway. Docker and Tailscale each insert their jump at the **top** of
> `FORWARD` when they start, so the service that started last wins. If Docker's `DOCKER-FORWARD` comes
> first, it accepts the packet before Tailscale can mark it, and Tor sees the NAS's own IP. At boot
> `tailscaled` started before Docker (09:16:52 and 09:17:06 on 2026-09-16), so Docker ended up on top.
> A later restart of `tailscaled` (for example Tailscale's auto-update) flips the order back.
> Starting `tailscaled` after Docker is no fix: the ports bound to the tailnet IP need it up first. Until 2026-09-16 the policy
> accepted only `172.16.0.0/12`. The first reboot in 69 days put Docker on top, and both Tor targets
> went down in Grafana while the bridges themselves kept running.

> **No `cap_add`, and the image must keep lyrebird free of file capabilities.** Tor's image sets
> `cap_net_bind_service=ep` on `/usr/bin/lyrebird`. Under `cap_drop: ALL` that capability is outside the
> bounding set, so the kernel refuses to exec the binary (`operation not permitted`). Tor then relaunches
> it every second and `4443` stays closed. Until 2026-09-16 the compose added `NET_BIND_SERVICE` back
> for that reason alone. The self-built image skips the `setcap` (`4443` needs no privilege), so the
> container runs with no capabilities at all. The build checks `lyrebird -version` under `--cap-drop ALL`.

## Dependencies

- **Oracle Security List** rules for `4443` and `9443` (a console action, see Access).
- **Tailnet NAS → A1** for the metrics scrape. The NAS is a user-owned node; the A1 is
  `tag:a1-matrix`. The current ACL already allows NAS → A1, as Komodo's use of the periphery's `:8120` shows.
- [Observability](observability.md) scrapes it (job `tor-bridge`).

## Notes

- **Egress budget.** Oracle's 10 TB/month of free egress covers the whole tenancy: micro ingress,
  Matrix, nightly backups to the NAS. The tenancy is Pay-As-You-Go, so overage is billed, not
  throttled. Tor's share is 2 TiB, split 1 TiB here and 1 TiB on the
  [WebTunnel bridge](a1-vps-webtunnel.md). Raise either cap only after checking *Cost Analysis*.
- **Shared host.** The bridge competes with Synapse and Kuma for CPU and bandwidth. Tor's own DoS
  defences (`tor_relay_dos_total` on the dashboard), the rate limit, and the 1 CPU / 512M
  container limit bound the damage.
- **Unlisted is not secret.** A bridge's IP is not in the public relay list, but determined censors
  enumerate bridges, and `198.51.100.20` is public anyway through Matrix DNS.
- **Oracle AUP.** Not confirmed either way for bridges. Tor operators report middle relays on
  Oracle's free tier without action. The worst case is losing the tenancy, which also holds the
  ingress and Matrix; see [a1-matrix-backup](../runbooks/backup-restore/a1-matrix-backup.md).

## Operations

SSH: `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20`

### Restart / redeploy

Komodo → Stacks → `a1-vps-tor-bridge` → **Deploy**, or push to `stacks/a1-vps-tor-bridge/`.
Identity and accounting state survive either way, because both live in `/opt/tor-bridge/data`.

### Bridge line, fingerprint, status

```sh
sudo cat /opt/tor-bridge/data/pt_state/obfs4_bridgeline.txt   # template: fill in IP, port 4443, fingerprint
sudo cat /opt/tor-bridge/data/hashed-fingerprint              # for Relay Search
sudo docker logs a1-tor-bridge 2>&1 | grep -iE 'reachab|bootstrapped|hibernat|accounting' | tail
```

### Image and security updates

The image is built in this repo, the same way as the [WebTunnel bridge's](a1-vps-webtunnel.md#image-and-security-updates):
[`build-obfs4-image.yml`](../../.github/workflows/build-obfs4-image.yml) builds
`ghcr.io/drizzelat/obfs4-bridge` for arm64 from [`Dockerfile`](../../stacks/a1-vps-tor-bridge/Dockerfile). The tag is
the lyrebird version.

**Why not Tor's image.** `thetorproject/obfs4-bridge` is only rebuilt when its repo gets a release. On
2026-09-16 the newest, `v0.25` from 2026-06-08, still shipped Tor 0.4.9.9, which the directory
authorities list as obsolete. Tor's apt repo already had 0.4.9.12.

**What goes in:**

- **lyrebird** (the obfs4 transport), compiled from source. The source comes through the Go module
  proxy, because gitlab.torproject.org bot-walls automated clients. Its `go.mod` has a `replace`
  directive, which `go install pkg@version` refuses, so the Dockerfile downloads the module and builds
  inside it. `-X main.lyrebirdVersion` sets the version lyrebird reports to Tor, as upstream's `make build` does.
- **Tor** from `deb.torproject.org`, on `debian:trixie-slim`, with `apt-get upgrade` at build time.
- **`start-tor.sh` and `get-bridge-line`**, copied from Tor's `thetorproject/obfs4-bridge` image, the
  only copy of those scripts outside GitLab. The compose env keeps working unchanged.
- **No file capability on lyrebird.** Tor's image runs `setcap cap_net_bind_service=+ep` on it,
  which is why the compose needed `cap_add: NET_BIND_SERVICE` until 2026-09-16 (see Configuration).
  `PT_PORT` 4443 needs no privilege.

**How updates reach the A1.** Nothing waits for a human:

| Upstream change | How it reaches the A1 |
| --------------- | --------------------- |
| Debian security fix, new Tor release | Every day at 03:40 Vienna, [`tor-bridge-image-trigger.sh`](../../scripts/tor-bridge-image-trigger.sh) dispatches the build workflow (its own `schedule:` at 03:25 UTC is a late fallback). It dry-runs `apt-get upgrade` inside the published image. Any pending package means a rebuild, pushed under the **same tag** with a new digest |
| New Go patch release, new `debian:trixie-slim` | Caught by the same run: the image's `nas.go-version` / `nas.base-digest` labels no longer match what a build would pull |
| New lyrebird release, new Go minor (`golang:1.27`), new `thetorproject/obfs4-bridge` release | Renovate opens a PR on the `Dockerfile`, which is **automerged** (`renovate.json`). The merge triggers a build, which pushes a new tag or digest. Renovate reads lyrebird's tags over git: they are `lyrebird-X.Y.Z`, so the Go proxy lists none |
| Any of the above, once pushed | Renovate's 04:15 run opens the compose PR → [renovate-pr-review](../runbooks/setup-operations/renovate-pr-review.md) → the 05:20 sweep merges it → `deploy-stacks` redeploys. Identity and accounting survive in `/opt/tor-bridge/data` |

Before pushing, a build runs its checks the way the compose file runs the container (`--cap-drop ALL`,
`no-new-privileges`):

- `tor --version` prints a version.
- `lyrebird -version` matches the Dockerfile.
- Both scripts are executable.
- `start-tor.sh`, given the compose env, renders a torrc that `tor --verify-config` accepts.

The weekly [`image-cve-scan`](../../.github/workflows/image-cve-scan.yml) covers the pinned image like every other.

To run a build by hand: `gh workflow run build-obfs4-image.yml -f force=true`. The GHCR package must
stay **public**: the A1 and the Renovate review pull it anonymously.

**Where it can still stall:** a review that comes back `RISK: REVIEW` (merge that compose PR by hand), a
failed build (GitHub sends its failure email), an automerged `Dockerfile` PR whose checks fail, or
Renovate being unable to read lyrebird's tags from GitLab (the Dependency Dashboard issue lists
lookup failures; bump `LYREBIRD_VERSION` by hand).

### Upgrade

See [Image and security updates](#image-and-security-updates). Tor keeps its identity across image
changes; nothing to migrate. Rollback = revert the compose pin and redeploy.

### Restore from backup

Nothing to restore. A rebuilt bridge with an empty data dir comes up as a new bridge (see Volumes).

### Common failures

- **Container exits right after start, DataDirectory permission error** → the host dir is not
  owned by uid 101. Re-run the `install -d` line from Volumes.
- **Log keeps saying the ORPort reachability test has not succeeded** → the Security List rule for
  `9443` (or `4443`) is missing.
- **Log repeats `Managed proxy "/usr/bin/lyrebird" ... terminated with status code 1`, `4443`
  refused** → lyrebird carries a file capability again, for example because the compose was pointed
  back at Tor's image (see Configuration). Confirm with
  `sudo docker exec a1-tor-bridge /usr/bin/lyrebird -version`, which prints `operation not permitted`.
  Fix the image, or add `cap_add: [NET_BIND_SERVICE]` as a stopgap.
- **`tor-bridge` target down in Grafana, container healthy** → from the NAS,
  `sudo docker exec victoriametrics wget -qO- http://100.64.0.13:9035/metrics`. A timeout points to
  the tailnet ACL. `error getting response` means `MetricsPortPolicy` rejected the source. The policy
  must accept both the NAS tailnet IP and the stack network's gateway (see Configuration). To see which
  one Tor gets: `sudo tcpdump -ni <bridge-if> 'tcp port 9035 and tcp[tcpflags] & tcp-syn != 0'` on the A1
  while the NAS scrapes. Check `sudo iptables -S FORWARD` for which of `DOCKER-FORWARD` and `ts-forward`
  comes first.
- **Throughput goes flat mid-month and the log mentions hibernation** → the 1 TiB cap was reached.
  Expected; it wakes up next month.

## Last updated

2026-09-16 — runs the self-built `ghcr.io/drizzelat/obfs4-bridge` (Tor 0.4.9.12, lyrebird 0.8.1) instead of
`thetorproject/obfs4-bridge:v0.25` (Tor 0.4.9.9, obsolete); `cap_add: NET_BIND_SERVICE` dropped.

2026-09-16 — `MetricsPortPolicy` also accepts the NAS tailnet IP: after a reboot Tor saw the NAS IP instead of the Docker gateway, and both Tor scrape targets went down.

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
