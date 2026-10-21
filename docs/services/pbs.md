# Service: Proxmox Backup Server

## Overview

A [Proxmox Backup Server](https://pbs.proxmox.com/) (PBS 4) on the NAS, as the backup target for
Proxmox VE hosts that are **not** on the home LAN. Today that is a lecture-course PVE host at a
teammate's home. PVE 9 pairs with PBS 4. The datastore holds deduplicated, compressed chunks of
the hosts' VM backups; the NAS only stores them, it never runs those VMs.

It is not part of the NAS's own backup chain. It is a backup of someone else's machines, and the
datastore itself is deliberately not carried offsite (backup.md).

### How the PVE host reaches it

The PVE host sits behind someone else's home router and may not run a VPN (course rule), so
nothing can connect *in* to the NAS and the host cannot join the tailnet. The `tunnel` container
connects *out* instead. It SSHes from the NAS, over the tailnet, to the host's `jumphost` VM, then
on to the PVE host, and asks that host's sshd to listen on **its own loopback `127.0.0.1:8007`**,
forwarded back to `pbs:8007`. PVE then talks to `127.0.0.1:8007` as if PBS were local.

```text
PVE host 127.0.0.1:8007  <--- ssh -R ---  tunnel container (NAS)  --->  pbs:8007
                                 via the jumphost VM, over the tailnet
```

- Nothing is exposed: no inbound port on the NAS, no listener on the VM network (the forward binds
  loopback on the PVE host only), no Tailscale node, no share, no ACL change, no auth key.
- The key (`pbs-tunnel@nas`) is restricted on both hops: on the jumphost it may only open
  `192.168.100.1:22`, and on the PVE host it may only listen on `127.0.0.1:8007`, open `127.0.0.1:8006` (the UI) and has no shell.
- The tunnel is the only dependency on the other host. If it is down, PVE backups fail and nothing
  else happens; `autossh` retries on its own.

## Stack

- **Stack folder:** `stacks/pbs/`
- **Compose file:** `stacks/pbs/docker-compose.yml`
- **Deploy:** Komodo Stack `pbs` on Server `nas` ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its
  folder deploys it through Komodo.
- **Image:** `ayufan/proxmox-backup-server`, a community build of the Proxmox packages. **There is
  no official PBS image**, and the Docker Hub description calls it unmaintained, although tags
  followed PBS releases through 2026-05. Renovate bumps it like any other pin. The fallback is a
  TrueNAS VM on the official ISO, like the runner VM.
- **Tunnel:** `jnovack/autossh`, a small autossh wrapper. Last built 2025-05; it is only `ssh`, and
  hand-written `command:` plus `ssh` from any image would do if it goes stale.

## Access

| | |
|---|---|
| URL | `https://pbs.example.com` (PBS) and `https://pve.example.com` (the lecture PVE host's web UI), LAN and tailnet only. `https://192.168.1.111:8007` still works on the LAN |
| Port | `8007/tcp` on the LAN IP; PVE uses `127.0.0.1:8007` on its own host, via the tunnel |
| Auth | PBS users. `admin@pbs` and `root@pbs` (both full admin; log in as `root` with the *Proxmox Backup authentication server* realm) and `guest@pbs` (full admin too, for the lecture teammate, see [pbs-guest](pbs-guest.md)) and `pve@pbs` with the API token `pve` (backup-only, for PVE). `pve.` is the PVE host's own login (`root@pam`). Passwords are in the gitignored `secrets/pbs-credentials.txt` |

Both names are `lan_only` Caddy vhosts like the other internal services (AdGuard's `*.example.com`
rewrite already points them at the NAS; Caddy's wildcard certificate covers them). Caddy reaches PBS
as `pbs:8007` and the PVE UI as `pbs-tunnel:8006` on the `proxy_pbs` network, both with the upstream's
self-signed certificate accepted. The PVE UI comes back through the **same** SSH session as the
backup tunnel: a second forward (`-L`) from the tunnel container, over the jumphost, to the PVE
host's own `127.0.0.1:8006`. Nothing new is opened on the PVE host's network, and the key may only
open that one port (`permitopen="127.0.0.1:8006"` next to the `permitlisten` for 8007).

PVE's noVNC and shell consoles are websockets; Caddy passes them through. If the tunnel is down,
`pve.` answers 502 and the backups fail too.

**Do not share the `nas` tailnet node with another tailnet to give someone access** — share [`pbs-guest`](pbs-guest.md) instead, which forwards only these two services. The `lan_only`
matcher admits all of `100.64.0.0/10`, so a guest's tailnet address would pass every internal vhost
(Komodo, TrueNAS, the *arr apps), not just these two.

The image ships with `admin@pbs` / `pbspbs`; it was changed after the first deploy. The CLI `user update --password` silently does nothing here, so change it in the UI (see the agent note).

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/etc/proxmox-backup` | `/mnt/apps/pbs/etc` | Users, ACLs, datastore list, the TLS certificate. Losing it means re-adding the datastore and a new fingerprint on every PVE host |
| `/var/lib/proxmox-backup` | `/mnt/apps/pbs/lib` | Job state, RRD metrics |
| `/var/log/proxmox-backup` | `/mnt/apps/pbs/logs` | Task logs |
| `/backups` | `/mnt/data/pbs` | Datastore `main` at `/backups/main`. Owned `34:34` (the image's `backup` user) |
| `/tunnel` (tunnel, ro) | `/mnt/apps/pbs/tunnel` | `id_ed25519` (private key, root `0400`), `known_hosts` (jumphost + PVE host keys), `ssh_config` (the `jump-host` / `pve-host` aliases). Hand-placed; the key is also in the vault as `secrets.enc/ssh/pbs-tunnel_ed25519.age` |

`apps/pbs` is a leaf dataset, so the nightly cloud sync carries the config offsite. `data/pbs` is a
leaf dataset with a **500 GB quota** (the `data` pool has about 1.2 TB free), and is not synced.

## Environment variables

None. The tunnel's `SSH_*` settings are plain compose values; the secret is the key file.

## Dependencies

- The [tailscale](tailscale.md) stack on the NAS, whose route to the jumphost's tailnet address the
  tunnel uses. (The jumphost is a node shared into your tailnet, which you can reach but which
  cannot reach you, hence the outbound tunnel.)
- Nothing else on the NAS. A PBS outage costs the PVE host its backups and nothing else.

## Configuration

| Setting | Value | Why |
|---|---|---|
| `ports` | `192.168.1.111:8007` | LAN admin UI only; PVE does not use it |
| `cap_drop` / `cap_add` | `ALL` / `CHOWN DAC_OVERRIDE FOWNER SETUID SETGID` | Tested on the NAS: the image's runit starts as root, chowns its three dirs and drops to `backup` for the proxy. Datastore create and login work with just these. `SYS_RAWIO` from the upstream compose is SMART-only and not needed |
| `tmpfs` `/run` | on | The image warns that PBS auth breaks without it |
| `stop_signal` | `SIGHUP` | Upstream's choice; the runit tree does not stop cleanly on SIGTERM |
| `SSH_BIND_IP` | `127.0.0.1` | The forward listens on the PVE host's loopback only, so no `GatewayPorts` change and nothing on the VM network |
| tunnel `read_only` / `cap_drop` | `true` / `ALL` | It only runs `ssh`; `/tmp` is a tmpfs for the agent socket |
| memory | 1.5 GB (PBS), 64 MB (tunnel) | Upstream suggests 2 GB; garbage collection is the peak |

## Setup

Once, in this order.

1. **Datasets** on the NAS (`ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.1.111`):

   ```sh
   sudo midclt call pool.dataset.create '{"name": "apps/pbs"}'
   sudo mkdir -p /mnt/apps/pbs/etc /mnt/apps/pbs/lib /mnt/apps/pbs/logs /mnt/apps/pbs/tunnel
   sudo midclt call pool.dataset.create '{"name": "data/pbs", "quota": 536870912000, "recordsize": "1M", "atime": "OFF"}'
   sudo chown 34:34 /mnt/data/pbs && sudo chmod 0700 /mnt/apps/pbs/tunnel
   ```

2. **Tunnel key and files** in `/mnt/apps/pbs/tunnel`. Generate `ssh-keygen -t ed25519 -N '' -C pbs-tunnel@nas`,
   keep it in the vault (`secrets/ssh/pbs-tunnel_ed25519` → `secrets.enc/ssh/`), and install it
   restricted on both hops:

   ```text
   jumphost  ~me/.ssh/authorized_keys : restrict,port-forwarding,permitopen="192.168.100.1:22" ssh-ed25519 AAAA… pbs-tunnel@nas
   PVE host  /root/.ssh/authorized_keys: restrict,port-forwarding,permitlisten="127.0.0.1:8007",permitopen="127.0.0.1:8006",command="/bin/false" ssh-ed25519 AAAA… pbs-tunnel@nas
   ```

   `known_hosts` holds the ed25519 host keys of the jumphost's tailnet address and `192.168.100.1`
   (take them from the hosts, not from a scan); `ssh_config` is:

   ```text
   Host pve-host
     HostName 192.168.100.1
     User root
     ProxyJump jump-host
   Host jump-host
     HostName <jumphost tailnet IP>
     User me
   Host *
     UserKnownHostsFile /tunnel/known_hosts
     StrictHostKeyChecking yes
     CheckHostIP no
   ```

   (`ProxyJump` does not inherit `-o UserKnownHostsFile`, which is why the host-key settings live in the file.)
3. **Merge.** `deploy-stacks` deploys the Stack; no Variables are needed.
4. **Admin password.** Open `https://192.168.1.111:8007` (`admin` / `pbspbs`, realm *Proxmox Backup
   authentication server*) and change it under the user menu.
5. **Datastore, PVE user and token** (from the NAS):

   ```sh
   sudo -n docker exec pbs sh -c '
   proxmox-backup-manager datastore create main /backups/main --gc-schedule "sat 03:30"
   proxmox-backup-manager verify-job create weekly-verify --store main --schedule "sun 04:00" --ignore-verified true --outdated-after 30
   proxmox-backup-manager user create pve@pbs --comment "PVE backup client"
   proxmox-backup-manager user generate-token pve@pbs pve
   proxmox-backup-manager acl update /datastore/main DatastorePowerUser --auth-id pve@pbs
   proxmox-backup-manager acl update /datastore/main DatastorePowerUser --auth-id "pve@pbs!pve"
   proxmox-backup-manager cert info | grep Fingerprint'
   ```

   `generate-token` prints the secret **once**; keep it for the PVE storage entry. The
   `DatastorePowerUser` (on `/datastore/main` only) lets PVE back up, read and prune its own snapshots, and
   nothing else. `DatastoreBackup` is not enough: the PVE-side `prune-backups` fails with
   `missing Datastore.Modify|Datastore.Prune`.

## Connecting a PVE host

On the PVE host (`root@pve`), nothing but a storage entry and a job. It talks to its own loopback:

```sh
pvesm add pbs pbs-nas --server 127.0.0.1 --datastore main \
  --username 'pve@pbs!pve' --password '<token secret>' --fingerprint '<sha256 fingerprint>' \
  --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=2
pvesh create /cluster/backup --storage pbs-nas --all 1 --schedule 02:30 --mode snapshot --bwlimit 10240 --enabled 1
```

Try one VM first: `vzdump 9001 --storage pbs-nas`. The first backup of a VM sends its used data
only (zero and duplicate chunks are skipped, the rest is zstd-compressed); a running VM then sends
just the blocks changed since the last run. A stopped VM is still scanned in full. The job caps the
rate at 10 MiB/s: the path is the PVE host's home uplink, which measured 2–25 MiB/s on the first
backup (a 32 GiB template took ~20 min and about 2 GB of datastore). If the host is moved (new LAN, the campus), the tunnel
needs the jumphost reachable and nothing else.

## Schedules

Backups are scheduled in two places, one per side. All times Europe/Berlin; the PVE host and the NAS
share that zone. Both are also in scheduled-tasks.md.

| When | What | Where it lives |
|---|---|---|
| 02:30 daily | `vzdump` of **all** VMs (`--all 1`, snapshot mode) to storage `pbs-nas`, capped at 10 MiB/s. Afterwards PVE prunes each guest to `keep-daily=7,keep-weekly=4,keep-monthly=2` (the storage's `prune-backups`). New VMs are picked up automatically | PVE host: *Datacenter → Backup*, or `pvesh get /cluster/backup` |
| Sat 03:30 | Garbage collection of datastore `main` | PBS: datastore option `gc-schedule` |
| Sun 04:00 | Verify job `weekly-verify`: re-reads chunks, skips snapshots already verified in the last 30 days | PBS: *Verify Jobs*, or `proxmox-backup-manager verify-job list` |

Order matters: backups first (02:30), GC after they finish (a chunk written by a running backup is
protected, but a collection racing the nightly run is needless), verification last. A first full backup
of a big VM can run past 03:30 on the home uplink; that is harmless.

Change the PVE job with `pvesh set /cluster/backup/<id> …` or in the UI. List the ids with
`pvesh get /cluster/backup`. A VM can be left out with `--exclude <vmid>` (or `--all 0 --vmid …`).
PVE mails failures to root on the PVE host (notification target `mail-to-root`), which nobody reads;
check *Datacenter → Tasks* or `ls -t /var/log/pve/tasks/*/*vzdump*` after a bad night.

**What backs up PBS itself.** The datastore (`data/pbs`) is not backed up, on purpose. The PBS config
(`apps/pbs`: users, token, certificate, datastore list, tunnel key) is covered by the recursive `apps`
snapshot tiers and the nightly Hetzner sync like every other `apps` leaf, with no task of its own.

## Operations

> Restart/redeploy go through **Komodo** (Stack `pbs`), which deploys from `komodo/resources.toml`. Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

Komodo → Stacks → `pbs` → **Restart** (bounce) or **Deploy** (pull and recreate). Or push to
`stacks/pbs/` → the runner deploys it through Komodo — see the deploy-stacks runbook.
Restarting `pbs` drops the tunnel's connection for a moment; `autossh` re-establishes it.

### Upgrade

Every image is pinned `tag@sha256:digest`. Renovate opens the bump PR, renovate-pr-review
reviews it, and the 05:00–06:00 sweep merges it if cleared. A PBS major bump (5.x) needs the PVE side
checked first: PVE and PBS are released as a pair. Rollback = revert the commit + redeploy; the
config in `apps/pbs/etc` is read forward-compatibly by the same major only, so restore a snapshot of
`apps/pbs` if a bump has already rewritten it.

### Restore from backup

- **PBS config lost** (`apps/pbs/etc`): restore the dataset from a local ZFS snapshot or Hetzner
  (backup runbook). Without it, re-run Setup steps 4 and 5: the datastore directory on `data/pbs` can be re-added with
  `proxmox-backup-manager datastore create main /backups/main --reuse-datastore true`, and the new
  certificate means a new fingerprint on the PVE storage entry.
- **Datastore lost** (`data/pbs`): not backed up. Recreate the dataset and datastore; the next
  scheduled backup per VM is a full one again. A ZFS snapshot of `data/pbs` restores quickly if one
  exists, but the snapshot tasks do not cover it.
- **Restoring a VM** on the PVE host: `qmrestore pbs-nas:backup/vm/<vmid>/<timestamp> <vmid>`, or the PVE UI → the storage → Backups.

### Common failures

- **Login fails for `admin@pbs`** right after a start: `/run` is not a tmpfs. Check `docker inspect pbs` for the `Tmpfs` entry.
- **PVE says "fingerprint mismatch"**: the certificate changed (`apps/pbs/etc` was reset). `proxmox-backup-manager cert info` and update the storage: `pvesm set pbs-nas --fingerprint …`.
- **PVE cannot connect to `127.0.0.1:8007`**: the tunnel is down. `docker logs pbs-tunnel` on the
  NAS; on the PVE host `ss -ltn | grep 8007` should show an `sshd` listener. Usual causes: the
  jumphost is off or off the tailnet, a host key changed (`Host key verification failed`, update
  `known_hosts`), or a stale listener on the PVE host after an unclean drop (`ExitOnForwardFailure`
  makes autossh retry until sshd clears it).
- **"Unable to open syslog" in the container log**: harmless; the image has no syslog daemon.
- **Datastore full**: the quota is 500 GB. Raise it on `data/pbs`, or tighten the prune schedule; PBS
  only frees space after a garbage collection (Saturday 03:30), not at prune time.
