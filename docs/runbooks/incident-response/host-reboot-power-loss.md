# Runbook: Full host reboot / power loss

What happens when the whole NAS goes down — planned reboot (TrueNAS update, kernel,
hardware) or unplanned (power cut) — and how to bring it back cleanly and verify it.

> Almost everything recovers **by itself**. TrueNAS imports the pools, the Docker
> service starts, and every container has `restart: unless-stopped`, so stacks come
> back without intervention. This runbook is the ordered checklist for the cases where
> something doesn't.

## Planned reboot — before you go down

1. Note anything mid-flight you don't want interrupted: the Cloud Sync chain (starts 03:00,
   runs until done — `/var/log/cloudsync-chain.log`), a large media import. Reboot outside those
   if you can.
2. If it's a TrueNAS upgrade, **export the config first** (manual download with the
   secret seed) — see [truenas-config-backup.md](../backup-restore/truenas-config-backup.md).
3. Reboot from the TrueNAS UI (**Power → Restart**) or `ssh … reboot`.

## After boot — startup order (what comes up on its own)

The host brings these up automatically; the order matters only for *dependencies*, and
Docker + `depends_on` already handle most of it:

1. **TrueNAS / ZFS** imports `boot-pool`, `apps`, `data`. No pool = stop and see
   [disk-failure-replacement.md](../incident-response/disk-failure-replacement.md).
2. **Docker** starts; containers with `restart: unless-stopped` (all of them) relaunch.
   dockerd is held back by an `ExecStartPre` until its ZFS data-root
   (`/mnt/.ix-apps/docker`) is actually **mounted** — without that it can win the race
   against the mount, come up with an **empty image store**, and fail every container
   with `layer does not exist` (2026-07-13). See
   [docker-image-prune.md](../setup-operations/docker-image-prune.md).
3. **Containers come back from their `restart:` policy**, Komodo's included. A POSTINIT
   [boot guard](../setup-operations/docker-image-prune.md) runs first and restarts docker if it
   came up blind anyway. Komodo Core (the `komodo` stack) and the `nas` periphery are ordinary
   containers: nothing waits on them, and nothing redeploys at boot.
4. **Core path** — bring-up that everything else leans on:
   - **AdGuard** (`:53`) — LAN DNS. Until it's up, LAN name resolution may fail.
   - **caddy** (Caddy + CrowdSec) — the single front door; public + proxied-LAN hostnames
     depend on it. Public access also needs the **tailscale** stack up (the VPS reaches Caddy's
     `:8443` over the tailnet — [micro-vps-ingress.md](../../services/micro-vps-ingress.md)).
   - **tailscale before beszel** — the Beszel hub publishes on the tailnet IP
     `100.64.0.11:8090`; if `beszel` starts first its port bind fails and it stays down until
     redeployed.
   - **Authentik** — SSO for `files` and `immich` OIDC login, and a **hard start-order dependency** for `files`, which exits at startup if OIDC discovery fails.
5. **downloads** — `qbittorrent` / `sabnzbd` / `flaresolverr` wait for **gluetun** to
   report healthy (VPN tunnel up) before they start. A slow tunnel = a slow start here,
   which is normal.

## Verify after every boot

- [ ] Pools online: TrueNAS → Storage, or `zpool status` — `apps` and `data` `ONLINE`.
- [ ] LAN DNS resolves (AdGuard up): `nslookup nas.example.com 192.168.178.111`.
- [ ] Komodo reachable: `https://komodo.example.com` (LAN); all Servers `Ok`.
- [ ] All Stacks `running` in Komodo — no container stuck restarting. A dispatched
      `deploy-state-probe` checks this on every host at once.
- [ ] gluetun **healthy** and the VPN-bound clients (qbittorrent/sabnzbd) started.
- [ ] A public host loads (e.g. `https://immich.example.com`) → caddy + VPS/Tailscale ingress OK.
- [ ] An SSO app hands off to Authentik (e.g. Mealie's *Login with authentik*) → Authentik OK.
- [ ] `beszel` is running (see the tailscale ordering above).
- [ ] No new alerts in Uptime Kuma / Beszel; the `nas` check on healthchecks.io is green.

## Unplanned power loss — extra checks

Dirty shutdown, so look for inconsistency the clean path wouldn't leave:

- **ZFS** is transactional — pools import consistent. A scrub isn't required, but if the
  outage was during heavy writes, kick a manual scrub on `data` (TrueNAS → Data
  Protection → Scrub) and watch for errors. The `data` mirror self-heals; the single-disk
  `apps` pool can only *report* corruption — if it shows errors, restore from backup
  ([backup.md](../backup-restore/backup.md)).
- **SQLite-backed apps** (kuma, homarr, files, questarr, beszel, grafana) can have a stale
  lock or a WAL to replay. If one won't start, check its container logs (Komodo, or `sudo docker logs`);
  worst case restore that one dataset from the latest snapshot.
- **Postgres** (authentik, immich, paperless, mealie, gamevault) and **MariaDB** (romm) do crash
  recovery on start.
  If a DB container loops on startup, restore from the logical dump
  ([postgres-dump.md](../backup-restore/postgres-dump.md)) rather than fighting the data dir.
- **A container stuck in "Restarting"** → open its logs (Komodo, or `sudo docker logs`); usually a missing
  env var (re-check the stack's Komodo Variables) or a dependency not yet healthy (give gluetun /
  Postgres time, or restart the stack once dependencies are up).

## If it doesn't power back on

- The host has **no public IP**; remote admin is via the **FritzBox WireGuard VPN**,
  which runs on the router and works even while the NAS is off — use it to send Wake-on-LAN.
  The board has no IPMI ([hardware.md](../../hardware.md)), so a host that will not power on
  needs someone at the box. See "Remote Administration" in [network.md](../../network.md).
- Pool won't import / a disk is missing → [disk-failure-replacement.md](../incident-response/disk-failure-replacement.md).
- Boot drive itself is dead → [disaster-recovery.md](../incident-response/disaster-recovery.md) scenario A.
