# Service: VPS node-exporter

## Overview

`node-exporter` on the Oracle micro VPS ingress host. Exports CPU, memory, load, network, disk I/O and filesystem fill, and the NAS
`victoriametrics` scrapes it over the tailnet (job `node`, label `host=micro`). The
[Hosts dashboard](observability.md#dashboards) in Grafana shows it. It replaced the Beszel agent on this host (retired 2026-10-03).

## Stack

- **Stack folder:** `stacks/micro-vps-node-exporter/`
- **Compose file:** `stacks/micro-vps-node-exporter/docker-compose.yml`
- **Deploy:** Komodo Stack `micro-vps-node-exporter` on Server `micro-vps`
  ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its
  folder deploys it through Komodo.
- **Runs on:** the Oracle micro VPS ingress host ([host + SSH details](micro-vps-ingress.md)).

## Access

No UI.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `9100/tcp` | `100.64.0.12` (tailnet) | Prometheus metrics, scraped by the NAS `victoriametrics`. Host network; never the public IP. The tailnet ACL lets the NAS (a member device) reach it |

The container needs the `tailscale` stack up first to bind the tailnet IP; after a reboot where it was not,
`restart: unless-stopped` retries until the address exists.

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/textfile` (`ro`) | `/var/lib/node-exporter-textfile` | `host.prom` with the per-container CPU and memory series, written by the host cron job `/etc/cron.d/host-metrics` ([observability → Host metrics](observability.md#host-metrics)), read by the `textfile` collector |
| `/probe/root` (`ro`) | `/var/lib/node-exporter-probe` | Empty probe dir on the root filesystem |

Root-disk usage without exposing the host: `statfs` of any path returns the usage of the whole filesystem it
sits on, so an **empty probe directory** bind-mounted read-only stands in for `/`. The exporter's `filesystem`
collector is limited to `^/probe/`, so each probe shows as one `mountpoint` label. Docker creates the
directories empty and root-owned on first deploy; each must sit on the filesystem it measures.

## Environment variables

None.

## Dependencies

- The `tailscale` daemon on the host, for the tailnet-IP bind.
- The NAS [observability](observability.md) stack, which scrapes it.
- The host cron job `/etc/cron.d/host-metrics`, which writes the textfile (setup in [observability](observability.md#host-metrics)).

## Notes

- Collectors on: `cpu`, `meminfo`, `loadavg`, `netdev` (physical NIC and `tailscale0`), `diskstats`,
  `filesystem` and `textfile`. No `hwmon` (the VM has no sensors), no `vmstat` and no `pressure`: the `OomKill` and
  `MemoryPressure` rules cover the NAS only.
- On start the exporter logs one `ERROR … Failed to open directory, disabling udev device properties` for
  `/run/udev/data`. It is harmless: the udev directory is not mounted, so disk metrics carry no model or serial labels.
- The box has 954 MiB of RAM; the exporter is capped at 64 MiB.

## Operations

> Redeploy is a **git push** to `stacks/micro-vps-node-exporter/`, or **Deploy** on the Komodo Stack. The `ubuntu` user needs
> `sudo docker` for host-side checks.

### Upgrade

`prom/node-exporter` pinned `tag@sha256` (see the compose file). It is the same image and pin as the NAS
exporter in [observability](observability.md#host-metrics); Renovate bumps each stack on its own.

### Common failures

- **`ScrapeTargetDown` for `100.64.0.12:9100`** → the container is down, or the tailnet is. On the host:
  `sudo docker ps --filter name=node-exporter` and `sudo tailscale status` (peer `nas` online).
- **Container restarting with `cannot assign requested address`** → `tailscale0` has no IP yet; it settles
  once tailscale is up.
- **No `mountpoint="/probe/..."` series** → the probe directory is missing from the mount list in the compose
  file, or the filter `^/probe/` no longer matches it.
