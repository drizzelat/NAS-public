#!/bin/sh
# Write the host metrics no container can read into node_exporter's textfile directory:
# ZFS dataset fill, Docker restart counts, per-container CPU and memory, NVMe wear, disk temperatures. Docs: docs/services/observability.md#host-metrics

set -u

# "containers" is the mode for the Oracle hosts: Docker restarts and per-container CPU and memory only,
# since they have no ZFS pool or S.M.A.R.T. devices.
MODE="${1:-all}"

OUT_DIR="${OUT_DIR:-/mnt/apps/observability/textfile}"
OUT="$OUT_DIR/host.prom"
TMP="$OUT.tmp"   # node_exporter reads *.prom only, so a half-written file is never scraped

mkdir -p "$OUT_DIR" && : >"$TMP" || { echo "host-metrics: cannot write $TMP" >&2; exit 1; }

section() {  # $1 = name, $2 = 1 on success; a failed section raises HostMetricsSectionFailing
  echo "host_metrics_section_ok{section=\"$1\"} $2" >>"$TMP.ok"
}
: >"$TMP.ok"

if [ "$MODE" = all ]; then
  # Pool roots and quota'd datasets only: every other child shares its pool's free space, so
  # its used/(used+avail) says nothing the root does not say sooner. TrueNAS's own .system/.ix-* are skipped.
  if rows="$(zfs list -Hp -t filesystem -o name,used,avail,quota,refquota 2>&1)" && [ -n "$rows" ]; then
    for metric in used avail; do
      col=2; [ "$metric" = avail ] && col=3
      echo "# TYPE zfs_dataset_${metric}_bytes gauge" >>"$TMP"
      echo "$rows" | awk -F'\t' -v col="$col" -v m="$metric" \
        '($1 !~ /\// || $4 > 0 || $5 > 0) && $1 !~ /\/\./ { printf "zfs_dataset_%s_bytes{dataset=\"%s\"} %s\n", m, $1, $col }' >>"$TMP"
    done
    section zfs 1
  else
    echo "host-metrics: zfs list failed: $rows" >&2
    section zfs 0
  fi
fi

# RestartCount is the daemon's own count of policy restarts; a recreate starts it from 0 again.
ids="$(docker ps -aq 2>/dev/null)"
# shellcheck disable=SC2086  # one argument per container id
if [ -n "$ids" ] && rows="$(docker inspect --format '{{.Name}} {{.RestartCount}} {{.Id}} {{or (index .Config.Labels "com.docker.compose.project") "-"}}' $ids 2>&1)"; then
  echo "# TYPE docker_container_restarts_total counter" >>"$TMP"
  echo "$rows" | awk '{ sub(/^\//, "", $1); printf "docker_container_restarts_total{name=\"%s\"} %s\n", $1, $2 }' >>"$TMP"
  section docker 1

  # CPU and memory come from the container's own cgroup (v2): the cgroupfs driver puts it under docker/,
  # the systemd driver under system.slice/. Working set = memory.current less reclaimable page cache.
  cpu_out=""; mem_out=""; lim_out=""; seen=0
  while read -r name _ id stack; do
    dir=""
    for d in "/sys/fs/cgroup/docker/$id" "/sys/fs/cgroup/system.slice/docker-$id.scope"; do
      [ -r "$d/cpu.stat" ] && dir="$d" && break
    done
    [ -n "$dir" ] || continue   # stopped, or no cgroup under either layout
    name="${name#/}"
    [ "$stack" = - ] && stack="$name"   # not a compose container: its own group
    usage="$(sed -n 's/^usage_usec //p' "$dir/cpu.stat")"
    current="$(cat "$dir/memory.current")"
    inactive="$(sed -n 's/^inactive_file //p' "$dir/memory.stat")"
    limit="$(cat "$dir/memory.max")"
    [ -n "$usage" ] && [ -n "$current" ] && [ -n "$inactive" ] || continue
    seen=$((seen + 1))
    cpu_out="${cpu_out}docker_container_cpu_usage_seconds_total{name=\"$name\",stack=\"$stack\"} $((usage / 1000000)).$(printf '%06d' $((usage % 1000000)))
"
    mem_out="${mem_out}docker_container_memory_working_set_bytes{name=\"$name\",stack=\"$stack\"} $((current - inactive))
"
    case "$limit" in max) ;; *) lim_out="${lim_out}docker_container_memory_limit_bytes{name=\"$name\",stack=\"$stack\"} $limit
" ;; esac
  done <<EOF
$rows
EOF
  running="$(docker ps -q 2>/dev/null | wc -l)"
  if [ "$seen" -gt 0 ] || [ "$running" -eq 0 ]; then
    echo "# TYPE docker_container_cpu_usage_seconds_total counter" >>"$TMP"
    printf '%s' "$cpu_out" >>"$TMP"
    echo "# TYPE docker_container_memory_working_set_bytes gauge" >>"$TMP"
    printf '%s' "$mem_out" >>"$TMP"
    echo "# TYPE docker_container_memory_limit_bytes gauge" >>"$TMP"
    printf '%s' "$lim_out" >>"$TMP"
    section cgroup 1
  else
    echo "host-metrics: no cgroup found for $running running containers" >&2
    section cgroup 0
  fi
else
  echo "host-metrics: docker inspect failed: ${rows:-no containers}" >&2
  section docker 0
  section cgroup 0
fi

if [ "$MODE" = all ]; then
# Enumerate via smartctl's own scan, like nvme-smart-test.sh, so a second NVMe needs no edit here.
devices="$(smartctl --scan 2>/dev/null | awk '$1 ~ /^\/dev\/nvme/ { print $1 }')"
nvme_ok=0
nvme_out=""
for dev in $devices; do
  # smartctl's exit status carries SMART flag bits even when the read worked, so only the JSON counts.
  if line="$(smartctl -j -a "$dev" 2>/dev/null | python3 -c '
import json, sys
log = json.load(sys.stdin)["nvme_smart_health_information_log"]
dev = sys.argv[1].rsplit("/", 1)[1]
for name, key in (("percentage_used", "percentage_used"), ("temperature_celsius", "temperature"),
                  ("critical_warning", "critical_warning")):
    print("nvme_%s{device=\"%s\"} %d" % (name, dev, log[key]))
' "$dev" 2>/dev/null)" && [ -n "$line" ]; then
    nvme_out="$nvme_out$line
"
    nvme_ok=1
  else
    echo "host-metrics: cannot read S.M.A.R.T. of $dev" >&2
    nvme_ok=0
    break
  fi
done
if [ "$nvme_ok" = 1 ]; then
  for name in percentage_used temperature_celsius critical_warning; do
    echo "# TYPE nvme_$name gauge" >>"$TMP"
    printf '%s' "$nvme_out" | grep "^nvme_$name{" >>"$TMP"
  done
else
  [ -n "$devices" ] || echo "host-metrics: no NVMe devices found" >&2
fi
section nvme "$nvme_ok"

# SATA/SAS drives only (NVMe is above). -n standby leaves a sleeping disk asleep: it reports no
# temperature and exits without waking it, so a spun-down disk is skipped, not a failure.
disks_ok=1
disk_out=""
for dev in $(smartctl --scan 2>/dev/null | awk '$1 !~ /nvme/ { print $1 }'); do
  if line="$(smartctl -n standby -j -A "$dev" 2>/dev/null | python3 -c '
import json, sys
t = json.load(sys.stdin).get("temperature", {}).get("current")
if t is not None:
    print("disk_temperature_celsius{device=\"%s\"} %d" % (sys.argv[1].rsplit("/", 1)[1], t))
' "$dev" 2>/dev/null)"; then
    [ -n "$line" ] && disk_out="$disk_out$line
"
  else
    echo "host-metrics: cannot read S.M.A.R.T. of $dev" >&2
    disks_ok=0
  fi
done
if [ "$disks_ok" = 1 ] && [ -n "$disk_out" ]; then
  echo "# TYPE disk_temperature_celsius gauge" >>"$TMP"
  printf '%s' "$disk_out" >>"$TMP"
fi
section disks "$disks_ok"
fi

echo "# TYPE host_metrics_section_ok gauge" >>"$TMP"
cat "$TMP.ok" >>"$TMP"
rm -f "$TMP.ok"
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
