# Service: syncthing

## Overview

Syncthing keeps the `smb_share` folders in sync between the NAS and each person's devices.
It replaces the SMB *mount* with a *sync*: every device holds a
local copy, works offline, and nothing hangs when the NAS is away. The NAS is the always-on node.
SMB keeps running beside it; folders move over one at a time (see [Rollout](#rollout)).

## Stack

- **Stack folder:** `stacks/syncthing/`
- **Compose file:** `stacks/syncthing/docker-compose.yml`

## Access

| | |
|---|---|
| URL | `https://syncthing.example.com` — the GUI, through Caddy (`lan_only`), no host port |
| Port | `22000/tcp` + `22000/udp` (sync, published on the LAN); GUI `8384` container-internal |
| Auth | Syncthing's own GUI user `admin`; the password is `STGUI_PASSWORD` in the vault (`syncthing.env`). No Authentik: the vhost is LAN/tailnet only |

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/var/syncthing` | `/mnt/apps/syncthing` | Config, keys (the device ID) and the index database |
| `/srv/smb_share` | `/mnt/data/smb_share` | The synced folders, the same tree SMB and [files](files.md) serve |

`/mnt/apps/syncthing` is its own `apps` dataset, owned by `568:568`. Create it before the first deploy:

```sh
sudo zfs create apps/syncthing && sudo chown 568:568 /mnt/apps/syncthing
```

## Environment variables

Nothing from the vault reaches the container: `syncthing.env` only holds the GUI login, which Syncthing keeps hashed in its own config. `STGUIADDRESS=0.0.0.0:8384` (a non-loopback address also turns off the GUI's
Host-header check, which Caddy would otherwise fail) and `STNODEFAULTFOLDER=1` are in the compose file.

## Dependencies

- `proxy_syncthing`, defined in `stacks/caddy` — the caddy change lands in the same push.
- `/mnt/data/smb_share` is UID/GID **568**. The container runs as `568:568` so SMB, `files` and
  Syncthing all see files they can write.

## Notes

- **No discovery, no relays.** Every device is on the LAN or the tailnet, so the NAS needs no public
  announcement. Local discovery (`21027/udp`) is not published either: broadcasts do not cross
  Docker's NAT. Devices add the NAS by address, `tcp://192.168.1.111:22000` at home or the NAS's
  tailnet name from outside (the subnet router carries the LAN IP too).
- **Not a backup.** A deletion on a phone is a deletion on the NAS. Each folder on the NAS gets
  **staggered file versioning**; `.stversions` lives inside `data/smb_share`, so sanoid snapshots
  and restic carry it too. Watch the dataset size: versions are the one thing here that grows on its own.
- **Conflicts** show up as `*.sync-conflict-*` files next to the original. SMB was last-writer-wins.
- **`roms` stays SMB.** The emulators read the ROM library over the share ([romm.md](romm.md)).

## Operations

> Restart/redeploy go through **Komodo** (Stack `syncthing`), which deploys from `komodo/resources.toml`. Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### First run

1. Create the dataset (above), merge, let `deploy-stacks` create and deploy the Stack.
2. Set the GUI login and turn off global and local discovery, relaying and NAT traversal. Done through
   the REST API on 2026-10-30 (`PATCH /rest/config/gui`, `/rest/config/options`). Redo both on a rebuilt node.
4. Kuma: add an HTTP monitor `Syncthing` (`https://syncthing.example.com`, parent `Services`) in
   the UI, then declare it in [`kuma/monitors/nas.toml`](../../kuma/monitors/nas.toml) — the
   deploy-state probe fails on a declared monitor the UI lacks (kuma-monitors).

### Rollout

1. Add one folder, e.g. `user1` at `/srv/smb_share/user1`, type **Send & Receive**, versioning
   **Staggered** (default max age 365 days).
2. On the device: add the NAS by its device ID and address, accept the folder share.
3. Live on it for a few weeks before moving the next folder. Retire a share's SMB access only once
   its owner has stopped using it.

### Restart / redeploy

Komodo → Stacks → `syncthing` → **Restart** (bounce) or **Deploy** (pull and recreate). Or push to
`stacks/syncthing/` → the runner deploys it through Komodo — see the
deploy-stacks runbook.

### Upgrade

Every image is pinned `tag@sha256:digest`. Renovate opens the bump PR,
renovate-pr-review reviews it, and the
05:00–06:00 sweep merges it if cleared. Syncthing migrates its index database on a major version.

### Restore from backup

- **A file or folder:** browse `.stversions/` in the folder, or `.zfs/snapshot/<name>/` of
  `data/smb_share`, and copy it back. Syncthing sends the restored file to the devices.
- **The node itself:** restore `apps/syncthing` (sanoid snapshot or restic). The keys in it are the
  device ID; a new ID means re-pairing every device.

### Common failures

- **GUI says "Host check error"** — `STGUIADDRESS` was changed back to a loopback address.
- **Device stays disconnected** — check the address is `tcp://192.168.1.111:22000` (or the tailnet
  name) and that `22000` is published (`sudo -n docker port syncthing`).
- **Permission denied writing a folder** — a file in it is not `568:568`, e.g. created over SMB by
  a user mapping. `sudo chown -R 568:568 <path>`.
