# Service: homeassistant

## Overview

[Home Assistant](https://www.home-assistant.io/) Core in a container: the smart-home hub. It runs on the
**host network** so that discovery works (mDNS/zeroconf for Chromecast, ESPHome, HomeKit and Matter
devices, SSDP for UPnP devices, DHCP watching). No radio hardware is attached yet: only LAN, Wi-Fi and
cloud integrations. LAN and tailnet only, like the other admin UIs.

This is the plain container install, so there are **no add-ons** (Supervisor is HA OS / Supervised only).
Anything an add-on would provide (Mosquitto, Zigbee2MQTT, ESPHome builder) goes in this stack as its own
service.

## Stack

- **Stack folder:** `stacks/homeassistant/`
- **Compose file:** `stacks/homeassistant/docker-compose.yml`

## Access

| | |
|---|---|
| URL | `https://ha.example.com` — Caddy `lan_only`, proxied to `http://192.168.1.111:8123` |
| Port | `8123` on the host network, closed to the LAN by the host firewall; see network.md |
| Auth | HA's own users, created at onboarding. Not behind Authentik: the companion app cannot follow a forward-auth redirect |

Remote access is over Tailscale, which reaches `ha.example.com` like any LAN client. The companion
app's server URL is `https://ha.example.com`.

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/config` | `/mnt/apps/homeassistant` | Everything: `configuration.yaml`, `.storage/` (UI-made config, users, auth tokens), `home-assistant_v2.db` (recorder history, SQLite), logs |

`apps/homeassistant` is its own leaf dataset, so the snapshot tiers and the offsite backup pick it up by themselves. The recorder DB is
SQLite inside the container, not a database server, so there is no logical dump (same as Kuma and
Jellyfin); a restore is the dataset.

## Environment variables

None. Timezone, location and units are set at onboarding and live in `.storage/`.

## Dependencies

- `caddy` for `ha.example.com`. Caddy reaches the host IP from a Docker bridge, so no `proxy_*`
  network is involved.
- `adguard` resolves `ha.example.com` to the NAS (the wildcard rewrite); no record was added.

## Notes

### Reverse proxy config

HA does not accept a forwarded request from a sender that isn't a trusted proxy (it logs
`A request from a reverse proxy was received from 172.16.25.128, but your HTTP integration is not
set-up for reverse proxies`). The settings in force:

```yaml
use_x_forwarded_for: true
trusted_proxies:
  - 172.16.0.0/16   # Caddy, from whichever Docker bridge holds its default route
ip_ban_enabled: true
login_attempts_threshold: 5
```

**Since 2026.10 they live in `/mnt/apps/homeassistant/.storage/http`, not in YAML.** That file holds
a `stable` config and a `pending` one. An `http:` block in `configuration.yaml` is imported once, as
`pending`, and the next start runs on it. An admin then has 5 minutes to confirm it (`http/config/promote`);
otherwise HA reverts to `stable`, restarts, and marks the pending one `not_promoted`, never to be
tried again. After that import (`yaml_migration_done: true`) the YAML block is ignored.

That is what happened at the first start: there was no admin yet, so the seeded block reverted. On
2026-10-29 it was promoted by hand: HA stopped, the `pending` dict copied into `stable` with
`error: null`, `pending: null`, HA started. Do that again only on an instance with no admin. Otherwise
change the settings in the UI (Settings → System → Network) and confirm within the 5 minutes. The
`http:` block still in `configuration.yaml` is inert, kept as the record of what was imported.

Caddy is attached to many `proxy_*` networks; a connection to the host IP leaves through its default
route, which is `proxy_adguard` (`172.16.25.0/24`) today. The whole Docker range is trusted so a change
of that route does not take HA down. Review: network.md → Proxy trust.

`ip_ban_enabled` writes banned client IPs to `ip_bans.yaml` in `/config`. With the proxy trusted, the
ban hits the real client, not Caddy. To lift one, delete its entry and restart.

### Host network and firewall

The NixOS host runs nftables ([`hosts/nas/network.nix`](../../hosts/nas/network.nix)), which drops
everything not listed. For HA that means:

- **`8123/tcp` is not opened.** Caddy arrives over a Docker bridge (`br-*`, accepted), the tailnet over
  the trusted `tailscale0`; a LAN client hitting `192.168.1.111:8123` times out. Use the Caddy name.
- **`5353/udp` is opened** so mDNS answers reach HA's zeroconf. No other mDNS responder runs on the
  host (no avahi), so there is no port clash.
- **SSDP replies** come back unicast from the device's `:1900` to HA's ephemeral port, which conntrack
  cannot tie to the multicast M-SEARCH: a rule accepts UDP from `192.168.1.0/24` with source port 1900.
- DHCP discovery sniffs with a raw socket and needs nothing.

The firewall is host config, applied with `nixos-rebuild switch`, not by Komodo. A later integration
that listens for inbound connections (HomeKit Bridge, Matter server, an MQTT broker for LAN devices)
needs its port added there too.

### After onboarding

Settings → System → Network: set **Home Assistant URL** both local and internet to
`https://ha.example.com`. Otherwise links in notifications and the companion app point at
`http://192.168.1.111:8123`.

## Operations

> Restart/redeploy go through **Komodo** (Stack `homeassistant`), which deploys from `komodo/resources.toml`. Over SSH, `truenas_admin` has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

Komodo → Stacks → `homeassistant` → **Restart** or **Deploy**. Or push to `stacks/homeassistant/` →
the runner deploys it through Komodo — see the
deploy-stacks runbook. A YAML change in
`configuration.yaml` also takes effect from HA's own Developer tools → **Restart**.

### Upgrade

The image is pinned `tag@sha256:digest`; Renovate opens the bump PR and the sweep merges it if the
review clears it (renovate-pr-review). HA ships a
monthly release (`YYYY.M.x`) whose notes carry a **Backward-incompatible changes** section per
integration; read the ones for integrations in use before a monthly bump merges. Rollback = revert the
commit + redeploy; a schema-migrated recorder DB may need the snapshot from before the upgrade.

### Restore from backup

Stop the stack → roll back `apps/homeassistant` from a local ZFS snapshot (or restore it from Hetzner)
→ start. General steps: backup runbook.

### Common failures

- **"not set-up for reverse proxies" or "untrusted proxy" in the log:** Caddy arrived from outside
  `trusted_proxies`, or the settings were reverted. Check `stable` in `.storage/http`; change them in
  the UI and confirm within 5 minutes ([Reverse proxy config](#reverse-proxy-config)). Editing the YAML
  does nothing.
- **Logged out with "banned":** a client hit `login_attempts_threshold`. Remove it from
  `/mnt/apps/homeassistant/ip_bans.yaml`, restart.
- **A discovered device never shows up:** check it is on `192.168.1.0/24`. Multicast does not cross
  Tailscale or VLANs.
