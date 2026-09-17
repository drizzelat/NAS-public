# Hardware

Physical build of the NAS host (`nas.example.com`, LAN `192.168.178.111`). Disk/pool layout
lives in [`docs/storage.md`](storage.md); this file is the compute/chassis side.

## Core components

| Part         | Spec                                                                 |
| ------------ | ------------------------------------------------------------------- |
| CPU          | Intel N100 (4C/4T, Alder Lake-N, ~6W TDP) — soldered to board       |
| Motherboard  | ASRock N100M (microATX, N100 SoC)                                    |
| RAM          | 32GB DDR4, non-ECC, 1x 32GB — board has a single DIMM slot (maxed)  |
| Boot/iGPU    | Intel UHD Graphics (Alder Lake-N, integrated) — QuickSync           |
| Case         | Jonsbo N4                                                            |
| PSU          | FSP Dagger Pro SDA2-650 (650W, SFX, 80+ Gold)                        |

> **RAM is maxed.** N100M has one DIMM slot, populated with the largest single stick (32GB).
> No expansion path without a board swap — keep an eye on ARC/app memory pressure.

## Storage controllers

N100M onboard provides only **2 SATA ports** + **1 M.2 (NVMe)**. Drive count exceeds onboard
SATA, so a PCIe SATA card adds the rest.

| Controller            | Type                  | Notes                                   |
| --------------------- | --------------------- | --------------------------------------- |
| Onboard SATA          | N100M chipset, 2 ports| Boot SSD + one HDD                       |
| PCIe SATA add-in card | AXAGON PCES-SA4X4 — 4x SATA 6G, PCIe gen3 x1, ASMedia ASM1064 | Extra SATA ports for remaining drive(s) |
| Onboard M.2           | NVMe                  | `apps` pool NVMe SSD                     |

Drives themselves (boot SSD, 2x 4TB HDD mirror, NVMe) → see [`docs/storage.md`](storage.md).

## GPU / transcoding

N100 integrated UHD Graphics. **QuickSync hardware transcode enabled** — `/dev/dri` passed to
the Jellyfin container ([`docs/services/jellyfin.md`](services/jellyfin.md)). No discrete
GPU.

## Network

- Onboard 1GbE NIC (Realtek). No 2.5G/10G, no add-in NIC.
- No IPMI / out-of-band management. Remote power-on relies on WoL; remote access via Tailscale
  (NAS-hosted) with FritzBox WireGuard as fallback when the NAS is off.

## Cooling

- CPU: passive heatsink (N100 fanless-class TDP).
- Case fans (Jonsbo N4): 1 above the CPU heatsink (airflow over the passive sink), 2 lower front
  for the drive cage.

## Power protection

- **No UPS yet.** On mains loss the host drops uncleanly — ZFS + nightly Hetzner backup are the
  safety net. See [`docs/runbooks/incident-response/host-reboot-power-loss.md`](runbooks/incident-response/host-reboot-power-loss.md).
  Candidate future add: UPS with USB/NUT to TrueNAS for graceful shutdown.
