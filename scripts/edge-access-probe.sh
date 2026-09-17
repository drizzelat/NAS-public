#!/bin/sh
# Layer 2 of the edge access policy: the questions only the ingress VPS can ask NPM.
# SSH forced command on the VPS; reads "<host> <claimed-client-ip>" lines on stdin.
# Docs: docs/runbooks/setup-operations/edge-access-policy-probe.md

set -u

NPM_HOST="${NPM_HOST:-100.64.0.11}"   # NAS tailnet IP
NPM_PORT="${NPM_PORT:-8443}"             # PROXY-protocol listener the VPS forwards to
DOMAIN="${PROBE_DOMAIN:-example.com}"
MAX_CASES="${MAX_CASES:-64}"

# The workflow compares this with the repo copy, so a hand-edited VPS copy is drift.
printf 'probe sha256=%s\n' "$(sha256sum "$0" | cut -d' ' -f1)"

curl --help all 2>/dev/null | grep -q -- --haproxy-clientip \
  || { echo 'error curl-too-old (needs --haproxy-clientip, curl >= 8.2)'; exit 2; }

n=0
while IFS=' ' read -r host claimed rest; do
  case "${host:-}" in ''|'#'*) continue ;; esac

  # Input arrives over SSH from CI: accept only a bare label and a dotted quad.
  case "$host" in -*|*[!a-z0-9-]*) echo "error bad-host"; exit 2 ;; esac
  case "${claimed:-}" in ''|*[!0-9.]*) echo "error bad-ip"; exit 2 ;; esac
  [ -z "${rest:-}" ] || { echo 'error extra-field'; exit 2; }

  n=$((n + 1))
  [ "$n" -le "$MAX_CASES" ] || { echo 'error too-many-cases'; exit 2; }

  fqdn="$host.$DOMAIN"
  # -k on purpose: this asserts the access policy, not the cert (the health check
  # owns expiry). --http1.1 keeps the deny exit code at 56 instead of an h2 92.
  code=$(curl -sk --http1.1 --max-time 15 \
    --haproxy-protocol --haproxy-clientip "$claimed" \
    --resolve "$fqdn:$NPM_PORT:$NPM_HOST" "https://$fqdn:$NPM_PORT/" \
    -o /dev/null -w '%{http_code}' 2>/dev/null)
  rc=$?

  printf 'result host=%s claimed=%s code=%s rc=%s\n' "$host" "$claimed" "$code" "$rc"
done

echo "done cases=$n"
