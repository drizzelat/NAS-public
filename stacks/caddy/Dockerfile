# The official caddy image has neither the Cloudflare DNS provider (needed for the
# *.example.com wildcard over DNS-01) nor a CrowdSec bouncer. docs/services/caddy.md
FROM caddy:2.11.7-builder-alpine@sha256:ef9b65adf9a224770c6d5f6d1ae1bf99bc3caaa78d8c4bae3ea949ee6984f301 AS builder

# Every module version is pinned, and Renovate bumps them (customManagers in renovate.json).
# Each --replace forces a patched dependency Caddy or a plugin still pins — docs/services/caddy.md → Image.
RUN xcaddy build \
      --with github.com/caddy-dns/cloudflare@v0.2.4 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.14.1 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/appsec@v0.14.1 \
      --replace golang.org/x/crypto=golang.org/x/crypto@v0.58.0 \
      --replace golang.org/x/net=golang.org/x/net@v0.62.0 \
      --replace golang.org/x/text=golang.org/x/text@v0.43.0 \
      --replace google.golang.org/grpc=google.golang.org/grpc@v1.85.0

FROM caddy:2.11.7-alpine@sha256:eb4d35b7452d1ab6171fbdbe8d9275b2301dad6dad92115d91e19fb9b24d510f
# Upstream rebuilds this base only with its Alpine base, so repo fixes lag; take them at build time.
RUN apk upgrade --no-cache
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
