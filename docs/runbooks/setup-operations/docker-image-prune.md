# Runbook: Docker image auto-prune + boot guard

> **The Portainer image guard is retired (2026-09-17).** Portainer was removed in SVC-2 Phase 3,
> and `scripts/portainer-image-guard.sh` went with it:
>
> - cron id 9 (the hourly guard) was deleted;
> - cron id 8 now runs only the prune;
> - Init/Shutdown script id 3 now runs only the boot guard.
>
> The prune, the boot guard and the lessons below still apply. The guard's own sections are kept as
> history, marked *(retired)*. No image on the estate has a layer-probing guard any more. A broken
> image is recovered by the stack's next Komodo deploy, which pulls it.

## Why

Three problems, one runbook:

1. **Unused images pile up.** Every `docker pull` (Renovate bumps, manual
   upgrades) leaves the superseded image behind. On the NAS pool and the two VPS
   boot disks they add up. The habit that formed to fix it — hand-removing
   "unused" images in the **Portainer UI** — is exactly what caused problem 2.

2. **Pruning an "unused" image once broke Portainer's layers.** Portainer runs as a
   TrueNAS **custom app** (it can't be a Portainer-managed stack — it can't manage
   itself), `restart: unless-stopped`, and is the GitOps controller + UI for every
   other stack. Removing an *unused tagged* image in the Portainer UI dropped an
   overlay2 **layer blob that Portainer's own image still shared**; on the next
   reboot the app died with `Error response from daemon: layer does not exist` and
   stayed down, taking the management UI + all webhook deploys with it.

3. **The guard itself destroyed metadata once (2026-07-13).** `dockerd`'s data-root is
   the ZFS dataset `apps/ix-apps/docker`, which TrueNAS mounts from **middleware, not
   systemd** — so nothing ordered docker.service after that mount. On one reboot dockerd
   won the race, initialised an **empty** image store against the bare mountpoint dir,
   and ZFS then mounted the real dataset underneath it. The daemon kept its empty view:
   **0 images, 0 containers**, while 498 layers and 48 images sat on disk. Every lookup
   failed with `layer does not exist` — *byte-for-byte the signature the guard exists to
   repair*. So it repaired: `rmi -f`, `pull`, then `docker image prune -af`. Those writes
   flushed the empty in-memory store back to disk and **overwrote
   `image/overlay2/repositories.json`**, wiping the tag map for **39 of 40 repos**. The
   image blobs were never damaged — the guard was the only thing that lost data.

   The race alone was recoverable (`systemctl restart docker` reloads everything). The
   guard is what turned it into data loss, because it had no way to tell "the image is
   broken" from "the daemon cannot see its own data".

The fix is **automated pruning** (so nobody hand-prunes in the UI) **paired with a
layer-aware guard** that detects a broken Portainer image and re-pulls it — at
boot, hourly, and immediately after every prune — plus a **boot guard** that keeps
dockerd from ever starting blind, and a **sanity gate** so the image guard refuses to
"repair" a daemon that cannot see its own data.

> **`docker image prune -a` is NOT inherently safe here.** The usual reassurance —
> "prune only removes images no container references" — does not protect against
> this failure: pruning an *unused* image removes layers no other **image** shares,
> and when the overlay2 layer store is inconsistent (e.g. after a power loss) that
> can drop a blob a *used* image still needs → `layer does not exist` on next
> start. Pruning was the **trigger**, not a bystander. That's why on the NAS the
> prune is always chained to the guard: any breakage it causes is detected and
> healed in the same run. The `-f` flag only skips the confirmation prompt; it is
> not `docker rmi -f`.

## Pieces

| File | Role | Runs on |
| --- | --- | --- |
| [`scripts/docker-image-prune.sh`](../../../scripts/docker-image-prune.sh) | Prune unused images older than 7d (`prune -a --filter until=168h`) | NAS + micro-vps + a1-vps |
| `scripts/portainer-image-guard.sh` *(retired 2026-09-17)* | Probed Portainer's pinned image for a missing image **or a missing layer blob**; repair (`rmi -f` + `pull`) if broken. **Refuses to repair a blind daemon** (sanity gate). Reads the digest from `stacks/portainer/docker-compose.yml` | NAS |
| [`scripts/docker-boot-guard.sh`](../../../scripts/docker-boot-guard.sh) | Install the systemd drop-in that blocks dockerd until its ZFS data-root is mounted; heal the current boot (restart docker) if the daemon already came up blind | NAS |

All three are portable POSIX `sh` and log to `/var/log/`; the prune also pings an optional
Uptime-Kuma push URL on success. Run as root (they need the docker socket).

### Age guard (`until=168h`)

Only images created **more than 7 days ago** are eligible. This keeps a
freshly-pulled image around long enough that `deploy-stacks.yml`'s auto-rollback
(revert to the previous compose on a failed health check) finds the old image
locally instead of re-pulling mid-incident. Override per run with arg 1 or
`DOCKER_PRUNE_UNTIL` (e.g. `720h` for 30 days).

### Portainer guard — why a presence check isn't enough *(retired)*

The original break was **not** a force-removed in-use image. Pruning an *unused
tagged* image dropped an overlay2 **layer blob** that Portainer's image still
shared; on the next reboot the app died with `Error response from daemon: layer
does not exist`. A plain `docker image inspect` **passes** in that state — the
manifest is fine, only a lower layer blob is gone — so a presence check would
have reported "ok" on a broken image.

So the guard **probes the layers**: it runs `docker create` on the image (the same
step that assembles the rootfs and surfaces "layer does not exist"). Only if that
succeeds is the image trusted. On a missing image *or* a failed probe it repairs:
targeted `docker rmi -f` + `docker pull`; if a shared broken blob survives that, it
falls back once to `docker image prune -af` + re-pull. `restart: unless-stopped`
(and, on a reboot, the TrueNAS app start) then brings Portainer up from the fresh
image on its own.

It does **not** hard-code the digest — it parses the `image:` line straight out of
`stacks/portainer/docker-compose.yml` in the on-NAS repo clone
(`/mnt/apps/scripts/nas`, kept fresh by [`git-pull-nas.sh`](nas-repo-autopull.md)),
so the pin never drifts. Idempotent — a healthy image = one throwaway `create`+`rm`.

> **Why the prune and the guard are chained on the NAS.** `docker image prune -a`
> is what triggered the incident, so on the NAS the guard runs *immediately after*
> every prune (same cron command, `;`-chained) — a prune that drops a shared layer
> is detected and healed in the same run, before anything reboots. The hourly +
> boot guard runs are the backstop.

## Deploy — NAS (TrueNAS)

Scripts run out of the repo clone, same pattern as the backup crons
([NAS repo auto-pull](nas-repo-autopull.md)).

> **As deployed** (2026-07-11, guard removed 2026-09-17): NAS cron id **8** = prune,
> Init/Shutdown script id **3** = POSTINIT boot guard. Cron id 9 (the hourly guard) is gone. Both VPS
> run the systemd `docker-image-prune.timer` (weekly Sun 04:30 UTC). First prune on
> the NAS reclaimed ~21 GB.

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
> clone both exist. This is the piece that self-heals a reboot following an
> accidental image deletion.

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

### The sanity gate (in `portainer-image-guard.sh`) *(retired)*

Before **any** destructive operation, the guard now proves the daemon's view matches the
disk, and aborts otherwise:

| Condition | Meaning | Action |
| --- | --- | --- |
| data-root is not a mountpoint | daemon's view is not authoritative | **ABORT**, exit 1 |
| `docker images -aq` = 0 **and** on-disk `imagedb` > 0 | daemon is **blind** (started pre-mount) | **ABORT**, exit 1 — run the boot guard / restart docker |
| views agree | genuine state | proceed (probe, and repair if really broken) |

This is what makes the `docker image prune -af` fallback safe: past the gate, "unused"
means unused. It is deliberately **kept**, not deleted — it is the only automated
recovery for problem 2 (a shared layer blob dropped by a UI prune). It was never wrong
in itself; it was wrong to run it against a daemon that could not see.


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
  `docker create`. The guard probes with `create`, not `inspect`, for exactly this.
- **First VPS install is manual** — no repo clone there; copy the script and set
  the timer once, then update by hand on change.
