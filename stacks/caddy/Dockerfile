# The official caddy image has neither the Cloudflare DNS provider (needed for the
# *.example.com wildcard over DNS-01) nor a CrowdSec bouncer. docs/services/caddy.md
FROM caddy:2.11.6-builder-alpine@sha256:096ec6e825e219175bd5be64b5e7a4000977f701a2bcaab825621d9fb1e1154b AS builder

# Every module version is pinned, and Renovate bumps them (customManagers in renovate.json).
# Each --replace forces a patched dependency Caddy or a plugin still pins — docs/services/caddy.md → Image.
RUN xcaddy build \
      --with github.com/caddy-dns/cloudflare@v0.2.4 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.14.1 \
      --with github.com/hslatman/caddy-crowdsec-bouncer/appsec@v0.14.1 \
      --replace golang.org/x/crypto=golang.org/x/crypto@v0.57.0 \
      --replace golang.org/x/net=golang.org/x/net@v0.60.0 \
      --replace golang.org/x/text=golang.org/x/text@v0.42.0 \
      --replace google.golang.org/grpc=google.golang.org/grpc@v1.84.0

FROM caddy:2.11.6-alpine@sha256:d44355d3c2149dc580ce2cac735955d1c08d3d00882c30489c241aa51a5c10d9
# Upstream rebuilds this base only with its Alpine base, so repo fixes lag; take them at build time.
RUN apk upgrade --no-cache
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
