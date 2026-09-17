# OS updates

How each host's operating system gets updated. Containers are not covered here: every image is
pinned in the repo and bumped by Renovate.

| Host | Updates | Reboot | Set up in |
| --- | --- | --- | --- |
| micro VPS, A1 | **automatic, every night**: Ubuntu security and `-updates` pockets, Docker 29.x point releases | automatic, only when an update requires one | [VPS hosts](#vps-hosts) below |
| runner VM | **automatic, every night**, the same set as the VPS hosts | automatic, only when an update requires one | [Runner VM](#runner-vm) below |
| NAS (TrueNAS) | **manual**; TrueNAS emails when an update is available | manual | [NAS](#nas-truenas) below |
| FRITZ!Box | automatic firmware update | automatic, 01:30 Vienna | [scheduled tasks](../../scheduled-tasks.md#fritzbox-firmware-auto-update--daily-0130-fritzbox-ui) |
| Tailscale on the VPS hosts | Tailscale's own auto-update (`AutoUpdate.Apply: true`), not apt | — | `tailscale set --auto-update` |

## VPS hosts

### What runs

| Host | Update run | Reboot, only if one is required |
| --- | --- | --- |
| A1 (`198.51.100.20`) | 22:15–22:25 UTC start — 00:15 Vienna in summer, 23:15 in winter | **23:15 UTC** — 01:15 Vienna in summer, 00:15 in winter |
| micro (`198.51.100.10`) | 22:45–22:55 UTC start — 00:45 Vienna in summer, 23:45 in winter | **23:45 UTC** — 01:45 Vienna in summer, 00:45 in winter |

Ubuntu's `unattended-upgrades` does the work, run by `apt-daily-upgrade.timer`. Three files per host
change its defaults, all added 2026-09-16:

- **`/etc/apt/apt.conf.d/60nas-auto-updates`**: which updates install, and the reboot.

  ```text
  Unattended-Upgrade::Allowed-Origins {
          "${distro_id}:${distro_codename}-updates";
  };
  Unattended-Upgrade::Origins-Pattern {
          "origin=Docker,archive=${distro_codename},label=Docker CE";
  };
  Unattended-Upgrade::Automatic-Reboot "true";
  Unattended-Upgrade::Automatic-Reboot-Time "23:15";   // 23:45 on the micro
  ```

  The lists add to Ubuntu's default `50unattended-upgrades` (security pocket and ESM) rather than
  replacing it. `noble-backports` stays manual.
- **`/etc/apt/preferences.d/docker-major-hold`**: pins `docker-ce`, `docker-ce-cli` and
  `docker-ce-rootless-extras` to `5:29.*` at priority 900. Every 29.x release outranks a 30.x
  release (priority 500), so point releases install on their own and a new major waits for you.
  `apt-cache policy docker-ce` shows `900` next to each 29.x version.
- **`/etc/systemd/system/apt-daily-upgrade.timer.d/nas-night.conf`**: moves the update run from
  Ubuntu's 06:00 UTC (+60 min random delay) to `22:15` (A1) or `22:45` (micro), with a 10-minute
  random delay.

**How the reboot is triggered.** At the end of every run, including a run that installed nothing,
`unattended-upgrade` checks for `/var/run/reboot-required`. If the file exists it calls
`shutdown -r 23:15`, and the host reboots about an hour after its update run. A night with no
kernel, libc or similar update doesn't reboot.

Before 2026-09-16 only security updates installed, at 06:00 UTC, and nothing rebooted: the micro
had been up 152 days on kernel `1007` with `1020` installed.

### Why these times

The host clocks are UTC, so the Vienna time moves by an hour with daylight saving time. Every slot
fits in summer and in winter:

- **Everything that restarts services runs at night.** A Docker update restarts `dockerd`, and
  with it every container on the host. The update run sits an hour before that host's reboot
  slot, so both outages fall in the same window.
- **A1 done before 02:00 Vienna.** The NAS pulls the A1's files at 02:00 and its database dumps at
  02:30, and both jobs ping [A1 Kuma push monitors](kuma-monitors.md#c-heartbeats-push). A
  rebooting A1 would fail the backup and set off its alarm.
- **Micro clear of the [edge access policy probe](edge-access-policy-probe.md)** at 00:17 Vienna
  (22:17 UTC in summer, 23:17 UTC in winter), which connects straight to the micro's public IP.
  A normal nightly batch is a few packages and finishes within minutes.
- **The two hosts 30 minutes apart.** Both usually get the same update on the same night.
  Staggering them means only one host is down at a time, and the A1 Kuma watchdog is up while the
  micro restarts.
- **Out of 03:00–07:00 Vienna**, the backup, Renovate and health-check window
  ([scheduled tasks](../../scheduled-tasks.md)).

Five minutes before a scheduled reboot, `pam_nologin` starts refusing SSH logins by non-root
users, so `ubuntu` cannot log in between 23:10 and 23:15 UTC (23:40–23:45 on the micro). Nothing
scheduled uses SSH to either host in that window.

### What it costs

Measured on 2026-09-16 while applying the backlog by hand (about 45 Ubuntu packages, Docker 29.8,
containerd 2.3), one host at a time:

| Host | Docker restart during the update | Reboot | Missed heartbeat pings on reboot |
| --- | --- | --- | --- |
| micro | public sites (tested with `jellyfin.example.com/health` through the VPS IP) down ~20 s | public sites down ~1.5–2 min | one (2 min gap) |
| A1 | Matrix `/_matrix/client/versions` down ~25 s | Matrix down ~70–80 s; NTP, Tor bridge and A1 Kuma for the same window | none |

Both heartbeat gaps fit inside the [healthchecks.io](external-heartbeat.md) period plus grace
(1 + 2 min), so a normal reboot does not raise a heartbeat alert. If a slower boot starts to, widen
the grace, as that runbook says. All containers returned on their own (`restart: unless-stopped`,
Docker enabled at boot).

A backlog is slow to apply: `unattended-upgrade` installs in small steps, and that batch took
24 minutes on the micro (1 GB RAM, no swap) and 6 on the A1. Nightly batches are a few packages.
Both batches needed a reboot (`apparmor`). On the micro, `fwupd.service` showed as failed after the
update removed its old library, and the reboot cleared it.

### Prerequisite: mount data volumes by UUID

A reboot is only safe if every data volume mounts by UUID. On the A1, `/etc/fstab` mounted
`/opt/matrix` by `/dev/oracleoci/oraclevda`. Oracle's udev rule gives that name to **both** the
boot disk (`sda`) and the 100 GB data volume (`sdb`), and whichever disk's udev event ran last
owns the link:

- On 2026-09-01 at 06:08 the link switched to the boot disk, the same minute unattended-upgrades
  installed `util-linux`, and stayed there.
- On a boot where the boot disk wins, the mount fails, and Docker (which fstab ties to the mount)
  does not start. Matrix, NTP, the Tor bridge and A1 Kuma all stay down until someone fixes it.
- After the 2026-09-16 reboots the link pointed at `sdb` again. Which disk gets it changes from
  boot to boot.

Fixed on 2026-09-16: the line now reads
`UUID=153236b6-951d-4118-b45f-12571cea83c1 /opt/matrix ext4 defaults,_netdev,nofail,x-systemd.required-by=docker.service,x-systemd.before=docker.service 0 2`.
The old file is at `/etc/fstab.bak-20260916`. [a1-provision](a1-provision.md) and
[matrix-deploy](matrix-deploy.md) now use the UUID form for new volumes. The micro has no data
volume.

### Operations

Run on the host (SSH commands: [network.md](../../network.md#cloud-hosts-oracle)).

```sh
systemctl list-timers apt-daily-upgrade.timer                      # next update run
ls /var/run/reboot-required && cat /var/run/reboot-required.pkgs   # reboot pending? why?
cat /run/systemd/shutdown/scheduled 2>/dev/null                    # reboot already scheduled? (USEC = epoch µs)
sudo shutdown -c                                                   # skip tonight's reboot; the next run schedules it again
tail /var/log/unattended-upgrades/unattended-upgrades.log         # what installed, what was kept back
apt-config dump | grep -E 'Origins|Automatic-Reboot'               # config in effect
sudo unattended-upgrade --dry-run -v                               # what the next run would install
```

- **Apply a backlog by hand** without a dropped SSH session killing dpkg halfway:
  `sudo systemd-run --unit=nas-uu-manual --collect /usr/bin/unattended-upgrade -v`, then wait for
  `systemctl is-active nas-uu-manual` to report `inactive`.
- **Move to a new Docker major:** read its release notes for API-version removals first (the Komodo
  periphery talks to the daemon API). Change `5:29.*` in
  `docker-major-hold`, then run the update by hand as above and watch the containers come back.
- **Stop automatic reboots on a host:** delete the two `Automatic-Reboot` lines from
  `60nas-auto-updates`, then `sudo shutdown -c` if one is already scheduled.
- **Move a slot:** edit the timer drop-in (`sudo systemctl daemon-reload` after) or the reboot time.
  Keep the update run before the reboot, and update the tables above and
  [scheduled tasks](../../scheduled-tasks.md).
- **A new host:** copy all three files with its own slots, and mount any data volume by UUID first.

### After a reboot or update, something did not come back

- **Micro, public sites down:** see [micro-vps-ingress → Reboot survival](../../services/micro-vps-ingress.md#reboot-survival).
- **A1, every container down:** check `systemctl status opt-matrix.mount docker`. A failed mount
  keeps Docker down by design. Confirm that `lsblk` shows the 100 GB disk, then
  `sudo mount /opt/matrix && sudo systemctl start docker`.
- **One container down:** run **Deploy** on that stack in Komodo.
- **An update broke something:** `grep -A3 "$(date +%F)" /var/log/apt/history.log` lists what
  changed. `sudo apt install <pkg>=<old-version>` rolls one package back, and
  `sudo apt-mark hold <pkg>` stops the next run from reinstalling the new version.

## Runner VM

The [runner VM](runner-vm.md) carries the same three files as the VPS hosts, written by cloud-init from
[`vm/runner-vm/user-data`](../../../vm/runner-vm/user-data), so a rebuilt VM has them from its first
boot. Checked live 2026-09-17 with the commands in [Operations](#operations), over
`ssh -i secrets/ssh/runner-vm_ed25519 ubuntu@192.168.178.34`.

| Update run | Reboot, only if one is required |
| --- | --- |
| 00:15–00:25 UTC start — 02:15 Vienna in summer, 01:15 in winter | **00:45 UTC** — 02:45 Vienna in summer, 01:45 in winter |

- **After both VPS hosts.** The micro's reboot slot is 23:45 UTC, so no two hosts restart at once.
- **Clear of the runner's night work.** The first scheduled job that needs the runner is the
  deploy-state probe at 03:47 Vienna.
- **Out of 03:00–07:00 Vienna**, like the VPS slots.

A reboot takes the Komodo Server `runner-vm` to `NotOk` for about a minute. A deploy-state probe run in
that minute fails.

## NAS (TrueNAS)

Updates stay manual. A TrueNAS update boots a new boot environment, and this host's reboot has
failure modes worth watching (see [host reboot](../incident-response/host-reboot-power-loss.md),
which also says to export the config first). What is automated is the **notice**:

- TrueNAS checks `update.check_available` every hour (alert source `HasUpdate`) and raises an
  "Update Available" alert when the selected train has a newer release. Auto-download is on, so the
  update is usually downloaded already.
- That alert is `INFO` by default, and the E-Mail alert service only sends `WARNING` and above.
  Since 2026-09-16 the class is raised to `WARNING`, so TrueNAS emails when an update appears:

  ```sh
  sudo midclt call alertclasses.update '{"classes": {"HasUpdate": {"level": "WARNING", "policy": "IMMEDIATELY"}}}'
  sudo midclt call alertclasses.config        # verify
  ```

  The setting lives in the TrueNAS config database, so it survives updates and is in the config
  backup.
- The [nightly health check](nas-health-check.md) reads `alert.list` and FAILs only on
  `CRITICAL`/`ERROR`, so a pending update shows there as a `warn:` line, not a red run.

**What it does not cover: moving to a new train.** `HasUpdate` only looks at the selected train.
On 2026-09-16 the NAS ran 25.04.2.6, the newest Fangtooth (25.04) release, and TrueNAS also offered
Goldeye (25.10). No alert fires for that; switching trains is a major upgrade to plan by hand.
