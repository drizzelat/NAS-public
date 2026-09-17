# Tor obfs4 bridge for the arm64 A1. Tor's thetorproject/obfs4-bridge is rebuilt rarely and fell behind Tor.
# Built and rebuilt by .github/workflows/build-obfs4-image.yml. Docs: docs/services/a1-vps-tor-bridge.md

# Cross-compiles on the runner's own arch, through the Go module proxy (gitlab.torproject.org bot-walls
# automated clients). go.mod has a replace directive, which `go install pkg@version` refuses.
FROM --platform=$BUILDPLATFORM golang:1.27-trixie AS build
ARG TARGETOS
ARG TARGETARCH
ARG LYREBIRD_VERSION=0.8.1
ENV CGO_ENABLED=0
RUN src="$(go mod download -json "gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird@lyrebird-$LYREBIRD_VERSION" \
      | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')" \
 && cp -r "$src" /src && chmod -R u+w /src && cd /src \
 && GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -trimpath \
      -ldflags="-s -w -X main.lyrebirdVersion=$LYREBIRD_VERSION" -o /out/lyrebird ./cmd/lyrebird

# Tor's archive key, accepted only if its fingerprint is the one Tor documents.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS keyring
ARG TOR_ARCHIVE_FINGERPRINT=A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gpg \
 && curl -fsSL "https://deb.torproject.org/torproject.org/$TOR_ARCHIVE_FINGERPRINT.asc" -o /tmp/tor.asc \
 && gpg --show-keys --with-colons /tmp/tor.asc | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "$TOR_ARCHIVE_FINGERPRINT" \
 && gpg --dearmor < /tmp/tor.asc > /tor-archive-keyring.gpg

# start-tor.sh and get-bridge-line, from the Tor image release they ship in: their repo is on the
# same bot-walled GitLab. Architecture-independent shell scripts, so the runner's own arch is fine.
FROM --platform=$BUILDPLATFORM thetorproject/obfs4-bridge:v0.25 AS upstream

FROM debian:trixie-slim
COPY --from=keyring /tor-archive-keyring.gpg /usr/share/keyrings/deb.torproject.org-keyring.gpg
# Fixed ids before the tor package would pick one: the host data dir is owned 101:101.
RUN groupadd -g 101 debian-tor \
 && useradd --system -u 101 -g 101 -s /usr/sbin/nologin -d /var/lib/tor debian-tor
# `upgrade` is what a rebuild is for: Debian security fixes newer than the base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && echo "deb [signed-by=/usr/share/keyrings/deb.torproject.org-keyring.gpg] https://deb.torproject.org/torproject.org trixie main" \
      > /etc/apt/sources.list.d/tor.list \
 && apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends tor tor-geoipdb \
 && rm -rf /var/lib/apt/lists/* /etc/tor/torrc \
 && chown debian-tor:debian-tor /etc/tor /var/log/tor
# No setcap, unlike Tor's image: PT_PORT is unprivileged, and a file cap outside the bounding set
# makes the exec itself fail under cap_drop: ALL.
COPY --from=build /out/lyrebird /usr/bin/lyrebird
COPY --from=upstream /usr/local/bin/start-tor.sh /usr/local/bin/get-bridge-line /usr/local/bin/
USER debian-tor
CMD ["/usr/local/bin/start-tor.sh"]
