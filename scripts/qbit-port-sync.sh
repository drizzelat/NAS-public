#!/bin/sh
# Keep qBittorrent's listen port on the port ProtonVPN forwards to gluetun, and write both ports to
# node_exporter's textfile directory. gluetun pushes the port itself, but only once and only for 2 min
# after a (re)connect; if qBittorrent is not answering by then, it stays on the old port until
# someone notices. Docs: docs/services/downloads.md#port-forwarding-sync
set -u

OUT_DIR="${OUT_DIR:-/mnt/apps/observability/textfile}"
OUT="$OUT_DIR/qbit-port.prom"
TMP="$OUT.tmp"   # node_exporter reads *.prom only, so a half-written file is never scraped

mkdir -p "$OUT_DIR" || { echo "qbit-port-sync: cannot create $OUT_DIR" >&2; exit 1; }

# Both come out as digits, or empty when the call failed.
forwarded_port() {
  docker exec gluetun wget -qO- -T 5 http://127.0.0.1:8000/v1/portforward 2>/dev/null \
    | sed -n 's/.*"port":\([0-9][0-9]*\).*/\1/p'
}
listen_port() {
  docker exec gluetun wget -qO- -T 5 http://127.0.0.1:8082/api/v2/app/preferences 2>/dev/null \
    | sed -n 's/.*"listen_port":\([0-9][0-9]*\).*/\1/p'
}

fwd="$(forwarded_port)"; fwd="${fwd:-0}"
cur="$(listen_port)";    cur="${cur:-0}"

# gluetun reports 0 while it has no forwarded port, and qBittorrent's port is unknown when its API is down:
# nothing to sync in either case, the alert reports it.
if [ "$fwd" -gt 0 ] && [ "$cur" -gt 0 ] && [ "$cur" != "$fwd" ]; then
  if docker exec gluetun wget -qO- -T 5 --post-data "json={\"listen_port\":$fwd}" \
      http://127.0.0.1:8082/api/v2/app/setPreferences >/dev/null 2>&1; then
    logger -t qbit-port-sync "listen_port $cur -> $fwd"
    cur="$(listen_port)"; cur="${cur:-0}"
  else
    echo "qbit-port-sync: setPreferences failed" >&2
  fi
fi

synced=0
[ "$fwd" -gt 0 ] && [ "$cur" = "$fwd" ] && synced=1

cat >"$TMP" <<EOF
# TYPE qbittorrent_forwarded_port gauge
qbittorrent_forwarded_port $fwd
# TYPE qbittorrent_listen_port gauge
qbittorrent_listen_port $cur
# TYPE qbittorrent_listen_port_synced gauge
qbittorrent_listen_port_synced $synced
EOF
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
