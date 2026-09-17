# Service: Psiphon Conduit

## Overview

A [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit) station on the NAS. Psiphon is a
censorship-circumvention network, and a Conduit station is one of its volunteer-run entry points.
Censored Psiphon users reach the station over WebRTC. It relays their encrypted tunnel on to Psiphon's own servers,
and **those** servers talk to the internet, not the NAS. It cannot see into the tunnels.

Like [Snowflake](snowflake.md), it is outbound-only and works behind CGNAT. Unlike Snowflake it serves
Psiphon users, not Tor users, so the two reach different people. In a 45-second test run on
2026-09-11 the broker was already handing it clients from Iran.

It has no access to NAS data. It gets one dedicated dataset for its key, a read-only root filesystem,
no capabilities and an unprivileged uid.

### Why the NAS

It needs no inbound port, so CGNAT does not matter. On the A1 it would draw from the same Oracle egress
pool as the two bridges and put a third circumvention service on that one IP. Psiphon's own guide
stresses IP diversity, and the home line is a different network entirely.

## Stack

- **Stack folder:** `stacks/conduit/`
- **Compose file:** `stacks/conduit/docker-compose.yml`
- **Deploy:** Komodo Stack `conduit` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.
- **Image:** `ghcr.io/psiphon-inc/conduit/cli`, Psiphon's official CLI image, which has the Psiphon
  network config built in.

## Access

No UI.

| Port | Bind | Purpose |
| ---- | ---- | ------- |
| `9998/tcp` | `192.168.178.111` | Prometheus metrics at `/metrics`, scraped by `victoriametrics` (job `conduit`) |
| UDP, ephemeral | host | WebRTC to clients, opened outbound through the NAT |

**Dashboard:** Grafana → *NAS (git)* → **Community services** (`community-services`), section
*Psiphon Conduit*: clients against the limit, throughput against `--bandwidth`, clients and traffic by
region. The raw series are `conduit_*` (`conduit_is_live`, `conduit_connected_clients`,
`conduit_bytes_uploaded`, `conduit_region_connected_clients` with label `region`).

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/home/conduit/data` | `/mnt/apps/conduit` | `conduit_key.json` (the station identity) and Psiphon's tunnel-core state |

> **The key is the station's reputation.** Psiphon's broker routes clients to stations that have
> performed well over time, tracked by this key. A new key starts from zero and can go hours or days
> without clients. That is why it lives on a leaf dataset, which is snapshotted and carried offsite by the
> cloud-sync chain, and not in an anonymous volume.
>
> **Create it before the first deploy**, owned by the image's uid:
>
> ```sh
> sudo midclt call pool.dataset.create '{"name": "apps/conduit"}'
> sudo chown 1000:1000 /mnt/apps/conduit && sudo chmod 0750 /mnt/apps/conduit
> ```

## Environment variables

None. All settings are flags in the compose `command:`.

## Configuration

| Setting | Value | Why |
| ------- | ----- | --- |
| `network_mode` | `host` | WebRTC NAT traversal already has CGNAT in the way; a Docker NAT on top only makes it worse (same as Snowflake) |
| `--max-common-clients` | `25` | Concurrent users; the default is 50. Psiphon measures 150–350 per CPU, so the N100 is not the limit, the uplink is |
| `--bandwidth` | `10` (Mbps) | Conduit's throughput limit; the default is 40. The home uplink also carries Snowflake and remote Jellyfin/Immich |
| `--metrics-addr` | `192.168.178.111:9998` | Not localhost: `victoriametrics` is on a bridge network |
| `user` / `read_only` / `cap_drop` | `1000:1000` / `true` / `ALL` | The image's own `conduit` uid. Tested on the NAS: it writes only to its data dir and needs no capability |

## Dependencies

- Outbound HTTPS to Psiphon's broker; UDP to clients.
- The `apps/conduit` dataset (see Volumes).
- [Observability](observability.md) scrapes it (job `conduit`).

## Notes

- **New stations are quiet.** Expect little traffic for the first hours or days while the broker builds
  up the key's reputation. Leave it running; Psiphon says idle capacity is still useful when networks change.
- **Exposure.** The home IP is not published anywhere, but the broker and the clients it sends can see it, as with Snowflake.
- **Uplink.** Conduit and Snowflake both upload through the home line. If remote streaming suffers,
  lower `--bandwidth` here. [Snowflake](snowflake.md) has no limit that works, only stopping it.
- **Psiphon is a company.** The broker, the reputation system and the servers users exit through belong to
  Psiphon Inc. The CLI is GPL-3.0. It is less transparent than Tor, but what the station itself does is
  in the published code.
- **Quota throttling** (`conduit-monitor`) exists for data-capped hosts. It is not used here; `--bandwidth` is the limit.

## Operations

> Restart/redeploy go through **Komodo** (Stack `conduit`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

Komodo → Stacks → `conduit` → **Restart** or **Deploy**, or push to `stacks/conduit/` (the runner deploys it
through Komodo). The key survives in
`/mnt/apps/conduit`.

### Logs

Komodo → Stacks → `conduit` → the service's **Log** (or `sudo docker logs conduit`). A `[STATS]` line reports how many clients are announcing,
connecting and connected, plus traffic and client regions.

### Upgrade

Renovate raises the `tag@sha256` pin. Rollback = revert the pin and redeploy.

### Restore from backup

Stop the stack, restore `apps/conduit` from a ZFS snapshot or Hetzner, then start it. It also works without
a restore, just with a new key and no reputation.

### Common failures

- **Restart loop with `permission denied` on `/home/conduit/data`** → `/mnt/apps/conduit` is not owned
  by `1000:1000`.
- **Crash loop with a bind error on `192.168.178.111:9998`** → the NAS LAN IP changed. Update
  `--metrics-addr` here and the `conduit` target in `stacks/observability/victoriametrics/scrape.yml`.
- **Running, but `Connected: 0` for days** → normal for a new key. Past a week, look for broker errors
  in the log and check that `conduit_is_live` is `1`.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack.

2026-09-15
