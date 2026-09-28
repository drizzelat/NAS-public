# Runbook: NAS avahi / mDNS disabled (overlong `deny-interfaces`)

The nightly health check reports **Check 3 (Host basics) FAIL** with
`avahi-daemon.service` in `failed` state. Root cause is a **malformed generated config**, not a
crash: avahi cannot parse its own `deny-interfaces=` line because it has grown too long.

avahi/mDNS is **deliberately masked** on this host — nothing relies on `truenas.local`, the NAS is
reached by IP (`192.168.178.111`) and by `nas.example.com`. If you see it `failed` again after a
TrueNAS update re-enabled it, re-apply the mask below.

## Root cause

TrueNAS regenerates `/etc/avahi/avahi-daemon.conf` from a mako template
(`/usr/lib/python3/dist-packages/middlewared/etc_files/local/avahi/avahi-daemon.conf.mako`, line
`deny-interfaces=${", ".join(deny_interfaces)}`). `deny_interfaces` is
`interface.internal_interfaces` — **every docker `br-*` bridge**, one per stack network. With ~39
bridges (42 networks) that line reached **796 characters**.

avahi's config parser reads each line into a fixed **256-byte** buffer (`fgets`). A line longer than
that is split mid-token; the second chunk starts with no `key=`, so avahi reports:

```
Missing assignment in /etc/avahi/avahi-daemon.conf:24: <r-c7120ca4e2f5, br-83581b2bd0a9, ...
```

and exits `255/EXCEPTION`. (The reported "line 24" is avahi's `fgets`-chunk counter, not a real file
line — the actual file's line 24 is a valid `allow-interfaces=`.)

It **cannot be shrunk durably**: the line fits only ~9 bridges, and we run one network per stack.
Hand-editing the conf is pointless — middleware rewrites it on the next network change.

## Why it stayed hidden until 2026-09-24

avahi parses its config **only at (re)start**, not continuously. It started cleanly at the
2026-09-08 boot, when the line still fit, and ran for two weeks. On **2026-09-23 16:23** a config
regeneration (a stack/network add or removal — `Files changed, reloading` in syslog) both pushed the
line past 256 bytes **and** triggered a full restart, which re-parsed the now-overlong line and
failed. The health check checks the systemd unit state, so it passed every night while the daemon was
still `running` and caught the failure on the **first** run after the restart (2026-09-24 04:30).

## Fix — mask it

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
sudo systemctl mask --now avahi-daemon.service avahi-daemon.socket
sudo systemctl reset-failed avahi-daemon.service   # clear the lingering failed state
systemctl --failed                                  # expect: 0 loaded units listed
```

Masking symlinks both units to `/dev/null`, so socket-activation can no longer start the broken
daemon. This is a **host-only** change (not repo-managed) and may need re-applying after a TrueNAS
major update, which can recreate the units.

## If you actually need mDNS again

Then masking is not an option and this becomes a TrueNAS bug to file upstream (overlong
`deny-interfaces` vs avahi's 256-byte line buffer). There is no clean interim mitigation while the
host runs this many docker networks.

## History

- **2026-09-24** — First occurrence. Health check Check 3 FAIL; avahi failed on 2026-09-23 16:23
  after a config regen grew `deny-interfaces` to 796 chars (39 bridges). User confirmed no reliance
  on `truenas.local`; avahi-daemon.service + .socket masked, failed state cleared. All other checks
  PASS.
