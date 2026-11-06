# The official caddy image has neither the Cloudflare DNS provider (needed for the
# *.example.com wildcard over DNS-01) nor a CrowdSec bouncer. docs/services/caddy.md
FROM caddy:2.11.7-builder-alpine@sha256:95a5e7e2692b5eb9545aadc5b90a39f6f509bee59c9508a493f83ee902eaef63 AS builder

# Every module version is pinned, and Renovate bumps them (customManagers in renovate.json).
# Each --replace forces a patched dependency Caddy or a plugin still pins — docs/services/caddy.md → Image.
RUN xcaddy build \
      --with github.com/caddy-dns/cloudflare@v0.2.4 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.15.0 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/appsec@v0.15.0 \
      --replace golang.org/x/crypto=golang.org/x/crypto@v0.58.0 \
      --replace golang.org/x/net=golang.org/x/net@v0.62.0 \
      --replace golang.org/x/text=golang.org/x/text@v0.43.0 \
      --replace google.golang.org/grpc=google.golang.org/grpc@v1.85.0

FROM caddy:2.11.7-alpine@sha256:e70b164da81ef698b3ad19af799ea6086ce6d9e48ed4079eb9fe26f6fbf14ee5
# Upstream rebuilds this base only with its Alpine base, so repo fixes lag; take them at build time.
RUN apk upgrade --no-cache
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
