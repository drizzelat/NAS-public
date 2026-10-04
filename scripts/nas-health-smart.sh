#!/bin/sh
# SMART reads for the nightly health check — the only part of it that needs root.
# Takes NO arguments, so its sudoers grant has nothing to inject into.
set -eu

SMARTCTL=/usr/sbin/smartctl

# smartctl exits non-zero on healthy disks too (bit 2 = some SMART attribute
# below threshold), so every call is `|| true` and the caller reads the text.
scan="$("$SMARTCTL" --scan 2>/dev/null || true)"
[ -n "$scan" ] || { echo "smartctl --scan found no devices"; exit 0; }

printf '%s\n' "$scan" | while read -r dev _rest; do
  case "$dev" in
    /dev/*) ;;
    *) continue ;;
  esac
  echo "=== $dev health + attributes ==="
  "$SMARTCTL" -H -A "$dev" 2>&1 || true
  echo "=== $dev selftest log ==="
  "$SMARTCTL" -l selftest "$dev" 2>&1 || true
done
