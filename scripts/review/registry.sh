# shellcheck shell=bash
# Registry API helpers for scripts/renovate-image-delta.sh and scripts/review/image-age.sh. Source it.
# Docs: docs/runbooks/setup-operations/renovate-pr-review.md

# Which CPU arch each stack runs on — a bump that only touched the other arch is
# a no-op here, so the right child manifest must be compared.
arch_for_file() {
  case "$1" in
    stacks/a1-vps-*)        echo "arm64" ;;
    *)                      echo "amd64" ;;
  esac
}

# ---------------------------------------------------------------- ref parsing

# docker.io/library/postgres:18.4@sha256:abc -> registry / repo / tag / digest
ref_registry() {
  local first="${1%%/*}"
  # A leading component is a registry only if it looks like a host.
  if [ "$first" != "$1" ] && { case "$first" in *.*|*:*|localhost) true ;; *) false ;; esac; }; then
    echo "$first"
  else
    echo "docker.io"
  fi
}

ref_repo() {
  local ref="$1" reg repo
  reg="$(ref_registry "$ref")"
  [ "$reg" = "docker.io" ] && [ "${ref%%/*}" != "docker.io" ] || ref="${ref#*/}"
  repo="${ref%%@*}"; repo="${repo%%:*}"
  # Docker Hub official images live under library/.
  if [ "$reg" = "docker.io" ] && [ "${repo#*/}" = "$repo" ]; then
    repo="library/$repo"
  fi
  echo "$repo"
}

ref_tag() {
  local rest="${1%%@*}"
  case "${rest##*/}" in *:*) echo "${rest##*:}" ;; *) echo "latest" ;; esac
}

ref_digest() {
  case "$1" in *@*) echo "${1##*@}" ;; *) echo "" ;; esac
}

# ---------------------------------------------------------------- registry API

# `docker.io` is the ref namespace, not an endpoint; its v2 API is registry-1.
api_host() {
  case "$1" in
    docker.io|index.docker.io) echo "registry-1.docker.io" ;;
    *)                         echo "$1" ;;
  esac
}

# Anonymous pull token, discovered from the registry's own 401 challenge.
declare -A TOKEN_CACHE=()
auth_token() {
  local reg="$1" repo="$2" key="$1|$2" chal realm service
  [ -n "${TOKEN_CACHE[$key]:-}" ] && { echo "${TOKEN_CACHE[$key]}"; return; }

  chal="$(curl -sS -o /dev/null -D - "https://$reg/v2/" 2>/dev/null \
          | tr -d '\r' | grep -i '^www-authenticate:' || true)"
  if [ -z "$chal" ]; then
    # No challenge at all — registry allows unauthenticated pulls.
    TOKEN_CACHE[$key]=""; echo ""; return
  fi
  realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$chal")"
  service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$chal")"
  [ -n "$realm" ] || { TOKEN_CACHE[$key]=""; echo ""; return; }

  local url="$realm?scope=repository:$repo:pull"
  [ -n "$service" ] && url="$url&service=$service"
  local tok
  tok="$(curl -sS "$url" | jq -r '.token // .access_token // empty')"
  TOKEN_CACHE[$key]="$tok"
  echo "$tok"
}

MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

get_manifest() {   # registry repo reference token
  local auth=()
  [ -n "$4" ] && auth=(-H "Authorization: Bearer $4")
  curl -sSf "${auth[@]}" -H "Accept: $MANIFEST_ACCEPT" \
    "https://$1/v2/$2/manifests/$3" 2>/dev/null
}

get_blob() {       # registry repo digest token
  local auth=()
  [ -n "$4" ] && auth=(-H "Authorization: Bearer $4")
  # -L: blobs 307 to object storage, and curl drops auth across hosts as expected.
  curl -sSfL "${auth[@]}" "https://$1/v2/$2/blobs/$3" 2>/dev/null
}

# Child manifest digest for one platform, or "" if this is not an index.
child_for_arch() {  # manifest-json arch
  jq -r --arg a "$2" '
    if (.manifests? // empty) then
      [ .manifests[]
        | select(.platform.architecture == $a and .platform.os == "linux")
        | select((.platform.variant // "") | test("^(v8)?$"))
        | .digest ] | first // ""
    else "" end' <<<"$1"
}
