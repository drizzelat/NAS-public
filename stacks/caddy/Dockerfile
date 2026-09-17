# The official caddy image has neither the Cloudflare DNS provider (needed for the
# *.example.com wildcard over DNS-01) nor a CrowdSec bouncer. docs/services/caddy.md
FROM caddy:2.11.4-builder-alpine@sha256:1a1689db91cfb390b2d856a1b3774e796852822cd723fa54c475b272f82bb4b7 AS builder

# Every module version is pinned, and Renovate bumps them (customManagers in renovate.json).
# Each --replace forces a patched dependency Caddy or a plugin still pins — docs/services/caddy.md → Image.
RUN xcaddy build \
      --with github.com/caddy-dns/cloudflare@v0.2.4 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.14.1 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/appsec@v0.14.1 \
      --replace golang.org/x/crypto=golang.org/x/crypto@v0.57.0 \
      --replace golang.org/x/net=golang.org/x/net@v0.59.0 \
      --replace golang.org/x/text=golang.org/x/text@v0.42.0 \
      --replace google.golang.org/grpc=google.golang.org/grpc@v1.83.2

FROM caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
# Upstream rebuilds this base only with its Alpine base, so repo fixes lag; take them at build time.
RUN apk upgrade --no-cache
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
