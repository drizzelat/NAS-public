# Runbook: NAS NIC packet loss (EEE / `r8169`)

The external Kuma (on the A1 — on the micro VPS before 2026-08-21) shows long/failed pings to the
NAS, or services feel flaky over Tailscale,
while the NAS itself is healthy (low load, plenty of RAM). Root cause is **silent packet
loss on the NAS's onboard Realtek NIC (`enp2s0`, `r8169` driver)** caused by **Energy
Efficient Ethernet (EEE / 802.3az)**.

> **Since 2026-09-17 the NAS's LAN address sits on the bridge `br0`**, with `enp2s0` its only port
> ([network.md](../../network.md#nas-host)). EEE belongs to the physical port, so every command here
> still names `enp2s0`, never `br0`. The [runner VM](../setup-operations/runner-vm.md) is bridged
> onto the same port, so the loss would hit it too.

## Symptom signature

- `~10%` ICMP loss from the NAS to **every** LAN peer (gateway, workstation), in **both**
  directions, on an **idle** link.
- Over the Tailscale tunnel this compounds into multi-second RTT spikes that **decrease
  ~1 s per packet** (a draining UDP buffer, e.g. `5231 → 4181 → 3157 → 2133 ms`) — looks
  like a routing/DERP problem but isn't.
- **Zero NIC error counters** — the drops are silent (`ip -s link show enp2s0` and
  `ethtool -S` show no growing `rx_errors`/`tx_dropped`).
- NAS `localhost` ping is perfect and `tailscale ping nas` is direct + fast (~4 ms), so the
  host stack and the tunnel are both fine — only packets crossing the physical NIC are lost.

## Confirm it's EEE, not something else

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
# EEE active? (the smoking gun)
sudo ethtool --show-eee enp2s0      # "EEE status: enabled - active"
# Rule out congestion — link should be idle:
#   sample /sys/class/net/enp2s0/statistics/{rx_bytes,tx_bytes} 1s apart → ~0 Mbps
# Rule out host load: uptime / free -h  → load low, RAM free
# Prove it's the physical link (not a client's wifi): ping the gateway FROM the NAS
ping -c 30 -i 0.2 192.168.178.1     # ~10% loss confirms NAS-side link
```

If instead you see a **duplex mismatch**, growing `rx_errors`, or `Link is Down` flaps in
`sudo dmesg -T | grep enp2s0`, suspect a **bad cable / switch port** — reseat / swap first.

## Fix

Disable EEE. It does **not** reset the link (won't drop your SSH) and is trivially reversible.

```sh
sudo ethtool --set-eee enp2s0 eee off
sudo ethtool --show-eee enp2s0 | grep -i "eee status"   # -> "EEE status: disabled"
```

Re-test — loss should go to **0%**:

```sh
ping -c 50 -i 0.2 192.168.178.1                 # from the NAS
ping -c 30 192.168.178.111                       # from a LAN client
ping -c 30 100.64.0.11                        # from a tailnet client (Kuma's view)
```

> **Note:** the first ping burst *immediately* after toggling EEE can look *worse* (the
> toggle triggers a brief link renegotiation). Wait ~10 s and re-sample before judging.

## Persistence (survives reboot)

`ethtool` settings are not persistent. A **TrueNAS Post-Init command** re-applies it at boot
(udev rules get wiped by TrueNAS updates — don't use those):

```sh
sudo midclt call initshutdownscript.create '{"type":"COMMAND","command":"ethtool --set-eee enp2s0 eee off","when":"POSTINIT","enabled":true,"timeout":10,"comment":"Disable EEE on enp2s0 (r8169 silent packet-loss fix)"}'
sudo midclt call initshutdownscript.query          # verify it's there
```

In the UI: **System Settings → Advanced → Init/Shutdown Scripts → Add** → *Type* Command,
*When* Post Init, *Command* `ethtool --set-eee enp2s0 eee off`.

## History

- **2026-07-08** — First occurrence. VPS-Kuma flagged long/failing pings to the NAS. EEE was
  `enabled - active` on `enp2s0`; disabling it took loss from ~10–40% (LAN) and 2–5 s tunnel
  RTT to 0% / single-digit ms. Post-Init script added (persists across reboot).
- **2026-09-17** — The LAN address moved onto the bridge `br0` for the runner VM. EEE on `enp2s0`
  was checked right after: still `disabled`.
