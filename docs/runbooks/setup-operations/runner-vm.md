# Runbook: the runner VM

## Overview

A classic TrueNAS virtual machine, `runnervm`, that hosts the self-hosted GitHub Actions runner
(SEC-1 step 4, [komodo-migration.md §6](komodo-migration.md#6-sec-1-step-4--the-runner-into-a-vm)).
The runner executes workflow code inside a VM, not in a container on the NAS host it deploys to.
Built 2026-09-17, runner moved in the same day. Not a stack: the VM itself is TrueNAS config, and
Docker inside it runs its [periphery](../../services/runner-vm-periphery.md) and the
[runner](../../services/github-runner.md).

## Host

| Field | Value |
| --- | --- |
| TrueNAS VM | `runnervm` (id 1), **Virtual Machines** screen (libvirt), autostart on |
| CPU / RAM | 2 cores / 2048 MiB |
| Boot | UEFI |
| Disk | zvol `apps/runner-vm`, 20 GiB sparse, virtio; Ubuntu 24.04 cloud image, root grown to 19 GiB |
| NIC | virtio on `br0`, MAC `00:a0:98:30:ac:6c` (pinned on the device) |
| Address | `192.168.178.34`, DHCP with a **FritzBox reservation** for that MAC |
| DNS | `1.1.1.1`, then `192.168.178.111` (AdGuard), set in netplan; the DHCP-offered DNS is ignored |
| SSH | `ssh -i secrets/ssh/runner-vm_ed25519 ubuntu@192.168.178.34` (key in the age vault); passwordless `sudo` |
| OS updates | nightly: `unattended-upgrades` at 00:15 UTC, reboot at **00:45 UTC** when required ([os-updates.md](os-updates.md)) |
| Docker | 29.x from docker.com, majors held; `ubuntu` is not in the `docker` group |
| Komodo Server | `runner-vm`, `https://192.168.178.34:8120` |

**Why a classic VM, and why `br0`** (plan F33):
- **Not Incus.** From TrueNAS 25.04.2 new VMs belong on the libvirt Virtual Machines screen. Incus
  VMs are legacy: no autostart, and their future is uncertain.
- **A bridge.** A classic VM's NIC attaches to a physical interface or a bridge. Attached to `enp2s0`
  directly (macvtap) it cannot reach its own host, and the runner needs the host: Caddy for Komodo,
  SSH as `nashealth`. So the NAS's LAN address moved to a bridge, `br0`, over `enp2s0`
  ([network.md](../../network.md#nas-host)).

**Why not AdGuard alone for DNS.** The FritzBox hands out AdGuard, on the NAS. With only AdGuard, a
broken AdGuard would leave the runner unable to reach GitHub, and CI is how AdGuard gets fixed. The
NAS host itself resolves `1.1.1.1` first, which is what the runner used while it ran there. Jobs never
rely on LAN names: every one that reaches a LAN-only host passes `--resolve` to the NAS's address.
Set 2026-09-17; the old netplan file is `/etc/netplan/50-cloud-init.yaml.bak-20260917`.

## Rebuild

The whole guest is [`vm/runner-vm/`](../../../vm/runner-vm/): a NoCloud seed (`user-data`, `meta-data`,
`network-config`) that installs Docker, the OS-update files and Core's public key.

1. **Build the seed ISO** on a workstation:
   `xorriso -as genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data network-config`.
2. **Prepare the disk on the NAS.** Download `noble-server-cloudimg-amd64.img` with its `SHA256SUMS`
   into a scratch directory outside every dataset that is backed up, and verify it. Create the zvol
   (`pool.dataset.create`, `type: VOLUME`, 20 GiB sparse), then
   `qemu-img convert -f qcow2 -O raw noble.img /dev/zvol/apps/runner-vm`.
3. **Create the VM.** `vm.create` (no `devices` field in 25.04.2), then `vm.device.create` for the
   DISK (virtio), a CDROM with the seed, and the NIC (virtio, `nic_attach: br0`,
   `mac: 00:a0:98:30:ac:6c`). Start it.
4. **Wait for cloud-init:** `cloud-init status` reads `done`.
5. **Clean up.** Stop the VM, delete the CDROM device (a device cannot be removed from a running VM),
   start it again, and delete the scratch directory.
6. **Apply the periphery** ([runner-vm-periphery.md](../../services/runner-vm-periphery.md)), then confirm the Server
   `runner-vm` is `Ok`.
7. **Bring up the runner:** Komodo → Procedures → `deploy-runner` → **Run**, or **Deploy** on the
   Stack `github-runner`. A new VM has no runner container, so it deploys straight away.

## Backup

None. The guest is stateless and rebuilt from `vm/runner-vm/`. The zvol is not a filesystem
dataset, so the cloud-sync chain skips it ([storage.md](../../storage.md)).

## Monitoring

The Komodo Server `runner-vm` is `Ok` only while the VM, its Docker and its periphery are up.
The deploy-state probe fails when it is not, and the nightly health check reports it (check 18).
Both run **on** this VM's runner, though. With the VM down their jobs sit queued, and GitHub fails
and emails them only after 24 hours. Kuma does not watch the VM.

## Common failures

- **No self-hosted job starts, or Server `runner-vm` NotOk after a NAS reboot** → the VM did not autostart: TrueNAS → Virtual
  Machines → `runnervm` → Start. If it is running, SSH in and check `sudo docker ps`.
- **The VM came up on another address** → the FritzBox reservation is gone. Re-pin
  `00:a0:98:30:ac:6c` to `192.168.178.34`; the periphery binds only that address.

## Last updated

2026-09-17 — the runner moved in (PR 11); DNS set to `1.1.1.1` then AdGuard.

2026-09-17 — built (SVC-2 Phase 3, PR 10).
