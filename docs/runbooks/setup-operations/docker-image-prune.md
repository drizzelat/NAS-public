# Runbook: Docker image auto-prune + boot guard

## Why

1. **Unused images pile up.** Every `docker pull` (Renovate bumps, manual upgrades) leaves the
   superseded image behind, on the NAS pool and on the two VPS boot disks.

2. **Hand-pruning breaks images.** Removing an *unused* image removes layers no other image
   shares — and when the overlay2 layer store is inconsistent (e.g. after a power loss) that can
   drop a blob a *used* image still needs. The next start fails with `layer does not exist`. It
   happened once, to the control plane. So pruning is automated, age-filtered and weekly, and
   nobody prunes by hand. A broken image is recovered by the stack's next Komodo deploy, which
   pulls it.

3. **dockerd can start blind.** Its data-root is the ZFS dataset `apps/ix-apps/docker`, which
   TrueNAS mounts from **middleware, not systemd** — so nothing orders docker.service after that
   mount. On one reboot dockerd won the race, initialised an **empty** image store against the bare
   mountpoint dir, and ZFS then mounted the real dataset underneath it: **0 images, 0 containers**,
   with every image still on disk. A `systemctl restart docker` recovers that. But any tool that
   writes to the image store in that state (a pull, an `rmi`, a prune) flushes the empty view back
   to disk and **overwrites `image/overlay2/repositories.json`** — a repair script once wiped the
   tag map for 39 of 40 repos that way. The boot guard keeps dockerd from starting blind.

## Pieces

| File | Role | Runs on |
| --- | --- | --- |
| [`scripts/docker-image-prune.sh`](../../../scripts/docker-image-prune.sh) | Prune unused images older than 7d (`prune -a --filter until=168h`) | NAS + micro-vps + a1-vps |
| [`scripts/docker-boot-guard.sh`](../../../scripts/docker-boot-guard.sh) | Install the systemd drop-in that blocks dockerd until its ZFS data-root is mounted; heal the current boot (restart docker) if the daemon already came up blind | NAS |

Both are portable POSIX `sh` and log to `/var/log/`; the prune also pings an optional
Uptime-Kuma push URL on success. Run as root (they need the docker socket).

### Age guard (`until=168h`)

Only images created **more than 7 days ago** are eligible. This keeps a
freshly-pulled image around long enough that `deploy-stacks.yml`'s auto-rollback
(revert to the previous compose on a failed health check) finds the old image
locally instead of re-pulling mid-incident. Override per run with arg 1 or
`DOCKER_PRUNE_UNTIL` (e.g. `720h` for 30 days).

## Deploy — NAS (TrueNAS)

Scripts run out of the repo clone, same pattern as the backup crons
([NAS repo auto-pull](nas-repo-autopull.md)).

> **As deployed:** NAS cron id **8** = prune, Init/Shutdown script id **3** = POSTINIT boot guard.
> Both VPS run the systemd `docker-image-prune.timer` (weekly Sun 04:30 UTC).

**Prune — cron job** (TrueNAS → System → Advanced → Cron Jobs, run as **root**):

| Schedule | Command |
| --- | --- |
| `30 4 * * 0` (Sun 04:30) | `/bin/sh /mnt/apps/scripts/nas/scripts/docker-image-prune.sh` |

**Boot guard — at boot** (TrueNAS → System → Advanced → Init/Shutdown Scripts). It heals a
blind daemon before anything else touches the image store:

| Type | Command | When |
| --- | --- | --- |
| `POSTINIT` | `/bin/sh /mnt/apps/scripts/nas/scripts/docker-boot-guard.sh` | Post Init |

> POSTINIT runs after the pool + apps are up, so the docker socket and the repo
> clone both exist.

### The boot guard (`docker-boot-guard.sh`)

Two jobs, both idempotent:

1. **Order dockerd after its data-root**, for every future boot. It writes
   `/etc/systemd/system/docker.service.d/10-wait-for-data-root.conf`, an `ExecStartPre`
   that blocks until `/mnt/.ix-apps/docker` is a real **mountpoint** (up to 120 s).

   > **Why not `RequiresMountsFor=`?** That resolves a path to a `.mount` unit — and a
   > ZFS dataset mounted by TrueNAS middleware **has no `.mount` unit at boot**. The
   > dependency would fail and docker would refuse to start *at all*, trading a
   > recoverable race for a hard boot failure. A wait loop blocks instead of failing.
   >
   > **Why reinstall it every boot?** A TrueNAS update boots into a **new boot
   > environment**, where `/etc/systemd` is the image's again and the drop-in is gone.
   >
   > **Why `mountpoint -q` and not `[ -d ]`?** The mountpoint *directory* always exists
   > (it is a plain dir on the parent dataset), so a path test passes in exactly the
   > broken case. Only "is a mount actually here" separates the two.

2. **Heal the current boot.** If the daemon reports **0 images** while the on-disk
   `imagedb` holds some, it came up blind → restart docker so it re-reads the mounted
   dataset. If the data-root is **not mounted at all**, it refuses to touch docker (a
   restart would just re-init an empty store on the bare dir — the original sin) and
   exits non-zero.

## Deploy — VPS (micro-vps, a1-vps)

The VPS hosts have no repo clone; copy the one script over and run it from a
systemd timer (survives reboots, journald-logged).

```sh
# on each VPS, as root — one file, no clone needed
install -m 0755 docker-image-prune.sh /usr/local/bin/docker-image-prune.sh

cat >/etc/systemd/system/docker-image-prune.service <<'EOF'
[Unit]
Description=Prune unused Docker images (safe, >7d)
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-image-prune.sh
EOF

cat >/etc/systemd/system/docker-image-prune.timer <<'EOF'
[Unit]
Description=Weekly Docker image prune

[Timer]
OnCalendar=Sun *-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now docker-image-prune.timer
```

The VPS stacks are ordinary Komodo Stacks; if a VPS image were ever removed, a Komodo deploy
re-pulls it (`auto_pull` is on for every Stack).

> Redeploy this script to the VPS by hand when it changes (no auto-pull there),
> the same way other host-side files are managed. The repo copy is the reference.

## Optional: Kuma heartbeat

To alert if a prune silently stops running, drop a Kuma **push** monitor URL into a
host file (not the repo):

```sh
# NAS + each VPS
echo 'https://<kuma>/api/push/<token>' > /root/.config/docker-image-prune-kuma-push.url
```

Kuma raises an alert when the ping is late. See [Kuma monitors](kuma-monitors.md).

## Verify / operate

```sh
# dry-look at what WOULD be pruned (images unused >7d), without removing
sudo docker image prune -a --filter "until=168h"   # then answer "n"

# run the prune now and watch the log
sudo /bin/sh /mnt/apps/scripts/nas/scripts/docker-image-prune.sh
sudo tail -n 20 /var/log/docker-image-prune.log

# VPS: timer status + last run
systemctl status docker-image-prune.timer
journalctl -u docker-image-prune.service --no-pager -n 20
```

## Gotchas

- **Never hand-prune images.** Removing an "unused" image can drop a shared layer blob and break a
  used image (`layer does not exist`). The weekly prune with its 7-day age filter is the only
  pruning; Komodo's `auto_prune` is off on every Server.
- **Presence ≠ healthy.** `docker image inspect` passing does **not** mean the
  image can start — a missing lower-layer blob passes inspect but fails
  `docker create`. Test a suspect image with `create`, not `inspect`.
- **First VPS install is manual** — no repo clone there; copy the script and set
  the timer once, then update by hand on change.
