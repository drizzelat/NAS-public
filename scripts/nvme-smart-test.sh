#!/bin/sh
# Run S.M.A.R.T. self-tests on NVMe devices — TrueNAS's own tasks silently skip
# them, and nvme0n1 is the whole non-redundant `apps` pool. See docs/scheduled-tasks.md.

set -eu

TYPE="${1:-short}"
case "$TYPE" in
  short|long) ;;
  *) echo "nvme-smart-test: unknown test type '$TYPE' (expected short|long)" >&2; exit 2 ;;
esac

command -v smartctl >/dev/null 2>&1 || {
  echo "nvme-smart-test: smartctl not found" >&2; exit 2; }

# Enumerate via smartctl's own scan, so a second NVMe needs no edit here.
devices="$(smartctl --scan | awk '$1 ~ /^\/dev\/nvme/ { print $1 }')"
[ -n "$devices" ] || { echo "nvme-smart-test: no NVMe devices found" >&2; exit 2; }

rc=0

for dev in $devices; do
  log="$(smartctl -l selftest "$dev" 2>&1)" || {
    echo "nvme-smart-test: $dev — cannot read self-test log:" >&2
    echo "$log" >&2
    rc=1
    continue
  }

  # The NVMe self-test log lists newest first; data rows start with the entry number.
  # A test started by the previous run is verdicted here — starting one is async.
  newest="$(echo "$log" | awk '/^[[:space:]]*[0-9]+[[:space:]]+(Short|Extended)/ { print; exit }')"
  if [ -z "$newest" ]; then
    echo "nvme-smart-test: $dev — self-test log is empty (no test has ever completed)" >&2
    rc=1
  elif ! echo "$newest" | grep -q "Completed without error"; then
    echo "nvme-smart-test: $dev — last self-test did NOT pass:" >&2
    echo "  $newest" >&2
    rc=1
  fi

  # Match the IDLE string, never a bare "in progress": that substring appears in
  # both status lines, so the naive check reads idle as busy and never starts a test.
  status="$(echo "$log" | grep -i '^Self-test status:' || true)"
  if [ -n "$status" ] && ! echo "$status" | grep -qi 'No self-test in progress'; then
    echo "nvme-smart-test: $dev — a self-test is already running, not starting a $TYPE test" >&2
    continue
  fi

  if ! out="$(smartctl -t "$TYPE" "$dev" 2>&1)"; then
    echo "nvme-smart-test: $dev — failed to start $TYPE self-test:" >&2
    echo "$out" >&2
    rc=1
    continue
  fi
  echo "nvme-smart-test: $dev — $TYPE self-test started"
done

exit "$rc"
