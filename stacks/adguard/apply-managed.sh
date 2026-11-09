#!/bin/sh
# post_deploy: make the live AdGuardHome.yaml match managed.yaml for every key in KEYS
# (docs/services/adguard.md → Config as code). Run from stacks/adguard in Komodo's clone.
# AdGuard writes its YAML back from memory on every UI save and on shutdown, so the file is only
# edited while the container is stopped. A change costs a few seconds of LAN DNS; no change, no restart.
set -eu
YQ=mikefarah/yq:4.47.1@sha256:b9285dd3b0bea3c34d0c54415dd48d767dabd9644d489bd6e253660847b58419
CONF=/mnt/apps/adguard/config
KEYS='.dns.upstream_dns .dns.bootstrap_dns .dns.fallback_dns .dns.upstream_mode .statistics.ignored
      .filters .whitelist_filters .user_rules .filtering.blocked_services .filtering.rewrites
      .clients.persistent'

# The periphery sees the clone at the host's own path, so $PWD works as a bind source.
yq() { docker run --rm --user 0 -v "$CONF:/conf" -v "$PWD/managed.yaml:/m.yaml:ro" "$YQ" "$@"; }
expr=$(for k in $KEYS; do printf '%s = (load("/m.yaml") | %s) | ' "$k" "$k"; done).
in_sync() { [ "$(yq '.' /conf/AdGuardHome.yaml)" = "$(yq "$expr" /conf/AdGuardHome.yaml)" ]; }

if in_sync; then
  echo "adguard: live config matches managed.yaml"
  exit 0
fi

echo "adguard: live config differs from managed.yaml, applying"
docker stop adguard >/dev/null
trap 'docker start adguard >/dev/null' EXIT
yq -i "$expr" /conf/AdGuardHome.yaml
docker start adguard >/dev/null
trap - EXIT
sleep 5
[ "$(docker inspect -f '{{.State.Running}}' adguard)" = true ] || { echo "adguard: not running after apply" >&2; exit 1; }
in_sync || { echo "adguard: live config still differs after apply" >&2; exit 1; }
echo "adguard: applied managed.yaml"
