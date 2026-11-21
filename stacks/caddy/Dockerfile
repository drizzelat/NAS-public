# The official caddy image has neither the Cloudflare DNS provider (needed for the
# *.example.com wildcard over DNS-01) nor a CrowdSec bouncer. docs/services/caddy.md
FROM caddy:2.11.9-builder-alpine@sha256:646fee578e680989ca5c7fd1ce6f1de574d19fd71ef2221810cc0510a9f40c86 AS builder

# Every module version is pinned, and Renovate bumps them (customManagers in renovate.json).
# Each --replace forces a patched dependency Caddy or a plugin still pins — docs/services/caddy.md → Image.
RUN xcaddy build \
      --with github.com/caddy-dns/cloudflare@v0.2.4 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.15.0 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/appsec@v0.15.0 \
      --replace golang.org/x/crypto=golang.org/x/crypto@v0.59.0 \
      --replace golang.org/x/net=golang.org/x/net@v0.63.0 \
      --replace golang.org/x/text=golang.org/x/text@v0.44.0 \
      --replace google.golang.org/grpc=google.golang.org/grpc@v1.85.0

FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
# Upstream rebuilds this base only with its Alpine base, so repo fixes lag; take them at build time.
RUN apk upgrade --no-cache
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
