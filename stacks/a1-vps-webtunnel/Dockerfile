# Tor WebTunnel bridge for the arm64 A1: Tor publishes thetorproject/webtunnel-bridge for amd64 only.
# Built and rebuilt by .github/workflows/build-webtunnel-image.yml. Docs: docs/services/a1-vps-webtunnel.md

# Cross-compiles on the runner's own arch. The Go module proxy and checksum DB stand in for
# gitlab.torproject.org, which bot-walls automated clients.
FROM --platform=$BUILDPLATFORM golang:1.27-trixie AS build
ARG TARGETOS
ARG TARGETARCH
ARG WEBTUNNEL_VERSION=v0.0.7
ENV CGO_ENABLED=0
RUN GOOS="$TARGETOS" GOARCH="$TARGETARCH" go install -trimpath -ldflags="-s -w" \
      "gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel/main/server@$WEBTUNNEL_VERSION" \
 && install -D -m 0755 "$(find "$(go env GOPATH)/bin" -type f -name server)" /out/webtunnel-server \
 && src="$(go mod download -json "gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel@$WEBTUNNEL_VERSION" \
      | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')" \
 && install -m 0755 "$src/release/container/start-tor.sh" "$src/release/container/get-bridge-line.sh" /out/

# Tor's archive key, accepted only if its fingerprint is the one Tor documents.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS keyring
ARG TOR_ARCHIVE_FINGERPRINT=A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gpg \
 && curl -fsSL "https://deb.torproject.org/torproject.org/$TOR_ARCHIVE_FINGERPRINT.asc" -o /tmp/tor.asc \
 && gpg --show-keys --with-colons /tmp/tor.asc | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "$TOR_ARCHIVE_FINGERPRINT" \
 && gpg --dearmor < /tmp/tor.asc > /tor-archive-keyring.gpg

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
COPY --from=build /out/webtunnel-server /usr/bin/webtunnel-server
COPY --from=build /out/start-tor.sh /out/get-bridge-line.sh /usr/local/bin/
USER debian-tor
# start-tor.sh writes any URL into torrc; a bridge line without a working one only strands its users.
ENTRYPOINT ["/bin/sh", "-c", "case \"$WEBTUNNEL_URL\" in https://?*/?*) exec /usr/local/bin/start-tor.sh ;; *) echo 'WEBTUNNEL_URL must be https://<domain>/<secret path>' >&2; exit 64 ;; esac"]
