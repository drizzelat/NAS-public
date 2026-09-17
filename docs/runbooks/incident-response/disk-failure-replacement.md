# Runbook: Disk failure / replacement

A drive is throwing SMART errors, a pool is `DEGRADED`, or TrueNAS alerted.
What it means per pool, and how to replace and resilver.

## Know the layout first

From [storage.md](../../storage.md):

| Pool | Disks | Redundancy | If a disk fails |
| --- | --- | --- | --- |
| `boot-pool` | boot SSD | single | OS unbootable → [disaster-recovery.md](../incident-response/disaster-recovery.md) scenario A |
| `apps` | 1× 250GB NVMe | **none (single disk)** | Pool **lost** → restore from backup, [disaster-recovery.md](../incident-response/disaster-recovery.md) scenario B |
| `data` | 2× 4TB HDD | **mirror** | Pool **survives degraded** → replace + resilver (below) |

> The `apps` pool has **no disk redundancy** — accepted risk, covered by snapshots +
> nightly Hetzner push instead of a mirror. A failing `apps` NVMe is a *restore*, not a
> resilver. The `data` mirror is the one you hot-replace.

## How a problem shows up

- **TrueNAS alert** (TrueNAS → Alerts) — the S.M.A.R.T. tasks run SHORT daily except Saturday and
  LONG on Saturday against the SATA disks.
- **NVMe self-test failure** — TrueNAS's own tasks silently skip NVMe, so
  [`nvme-smart-test.sh`](../../../scripts/nvme-smart-test.sh) covers `nvme0n1` (the whole `apps`
  pool) and emails on failure. See [scheduled-tasks.md](../../scheduled-tasks.md).
- **The nightly health check** reads SMART directly and turns the run red
  ([nas-health-check.md](../setup-operations/nas-health-check.md)).
- **Pool status** not `ONLINE`:

  ```sh
  ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
  zpool status -v data
  zpool status -v apps
  ```

  Look for `DEGRADED`, `FAULTED`, `UNAVAIL`, or non-zero `READ/WRITE/CKSUM` counts.

> Don't confuse this with the known **Patriot P210 `/dev/sda`** false negative-temperature
> reading — a firmware/SCT-log quirk, not a failing disk. `smartctl -a /dev/sda` shows the
> bogus value; every other attribute is what matters.

## Replace a disk in the `data` mirror (no data loss)

The mirror keeps serving reads/writes from the healthy disk while you swap the bad one.

1. **Identify** the failed disk — serial + slot. `zpool status -v data` gives the vdev
   GUID/name; map it to a physical serial in TrueNAS → **Storage → Manage Devices**, or:

   ```sh
   sudo smartctl -i /dev/sdX   # serial number to match the physical label
   ```

2. **Offline it** (if not already faulted): TrueNAS → Storage → the pool → device →
   **Offline**.
3. **Physically replace** the drive (hot-swap if the bay supports it; otherwise power
   down, swap, boot).
4. **Replace in TrueNAS** → Storage → the degraded pool → **Replace** the offlined device
   with the new disk. TrueNAS starts a **resilver** (rebuild onto the new disk).
5. **Watch the resilver**:

   ```sh
   zpool status data    # shows "resilver in progress" + ETA, then "resilvered"
   ```

   Don't reboot mid-resilver if avoidable. When done, the pool returns to `ONLINE`.
6. **Confirm** no lingering errors (`zpool status -v data`); clear counters if needed
   (`sudo zpool clear data`). Check the next scheduled **scrub** (data: Mon 00:00) runs clean.

## `apps` NVMe failure (single disk — restore, not resilver)

There is no second disk to rebuild from. Treat it as data loss on `apps` and restore:

1. Replace the NVMe; recreate the `apps` pool + datasets (layout in [storage.md](../../storage.md);
   the TrueNAS config defines it).
2. Restore config dirs from Hetzner and Postgres from logical dumps — full steps in
   [disaster-recovery.md](../incident-response/disaster-recovery.md) **Scenario B**.
3. Worst-case loss = changes since the last nightly push (config churn is small; the
   every-4h `apps` snapshots only help if the *pool* survived, which here it didn't).

## Boot drive failure

Pools are untouched; only the OS is gone. Reinstall TrueNAS and restore the config —
[disaster-recovery.md](../incident-response/disaster-recovery.md) **Scenario A**.

## After any replacement

- [ ] Pool `ONLINE`, zero error counters.
- [ ] `smartctl --scan` and `zpool status` show the new disk; old serial gone.
- [ ] Next scrub completes clean ([storage.md](../../storage.md) → Disk health schedule).
- [ ] If you replaced the `data` mirror, confirm SMART tests are scheduled against the new
      disk (TrueNAS → Data Protection → S.M.A.R.T. Tests target "all disks", so it's
      automatic).
- [ ] Update the disk table in [storage.md](../../storage.md) if sizes/labels changed.
