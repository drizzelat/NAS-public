#!/usr/bin/env bash
# Build the sanitized public mirror tree from this checkout's HEAD: export.sh <out-dir>
# Fails closed: <out-dir> is only created once every gate passes. docs/runbooks/setup-operations/public-mirror.md
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
rules=$here/rules
out=${1:?usage: export.sh <out-dir>}
[ ! -e "$out" ] || die "$out already exists"
command -v gitleaks >/dev/null || die "gitleaks is not on PATH"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tree=$tmp/tree
mkdir "$tree"
git -C "$repo" archive --format=tar HEAD | tar -x -C "$tree"

excludes=()
d=$'\001'   # sed delimiter that no pattern can contain
: >"$tmp/scrub.sed"
: >"$tmp/checks"
: >"$tmp/allow-ip"
while IFS= read -r line; do
  case $line in '' | '#'*) continue ;; esac
  kind=${line%% *} arg=${line#* }
  case $kind in
    exclude) excludes+=("$arg") ;;
    scrub)
      pat=${arg%% => *} rep=${arg#* => }
      printf 's%s%s%s%s%sg\n' "$d" "$pat" "$d" "$rep" "$d" >>"$tmp/scrub.sed"
      printf '%s\n' "$pat" >>"$tmp/checks"
      ;;
    deny) printf '%s\n' "$arg" >>"$tmp/checks" ;;
    allow-ip) printf '%s\n' "$arg" >>"$tmp/allow-ip" ;;
    *) die "rules: unknown kind '$kind'" ;;
  esac
done <"$rules"

for p in "${excludes[@]}"; do
  [ -e "$tree/$p" ] || die "rules: excluded path '$p' is not in the repo any more"
  rm -rf "${tree:?}/$p"
done

{
  cat <<'EOF'
> **Public mirror.** A sanitized, read-only copy of a private homelab repo, synced on every push.
> Secrets, the encrypted vault and some internal docs are left out; domains, public IPs, SSH keys
> and personal details are replaced with example values, so nothing here deploys as-is.
> Links to pull requests and removed files do not resolve.

EOF
  cat "$tree/README.md"
} >"$tmp/README.md"
mv "$tmp/README.md" "$tree/README.md"

find "$tree" -type f -exec grep -IlZ '' {} + | xargs -0 -r sed -E -i -f "$tmp/scrub.sed"

# Gate 1: no scrub or deny pattern may survive, in contents or in paths.
if grep -rnaiE -f "$tmp/checks" "$tree" | sed "s|^$tree/||"; then
  die "a scrub or deny pattern still matches (above)"
fi
if (cd "$tree" && find . | grep -iE -f "$tmp/checks"); then
  die "a scrub or deny pattern matches a path (above)"
fi

# Gate 2: every IPv4 token is private, CGNAT, documentation, special-use or allowlisted.
bad=$(grep -rhoaE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$tree" | sort -u | awk -F. -v allow="$tmp/allow-ip" '
  BEGIN { while ((getline ip < allow) > 0) ok[ip] = 1 }
  { a = $1 + 0; b = $2 + 0; c = $3 + 0 }
  a == 0 || a == 10 || a == 127 || a >= 224 { next }
  a == 100 && b >= 64 && b <= 127 { next }
  a == 169 && b == 254 { next }
  a == 172 && b >= 16 && b <= 31 { next }
  a == 192 && b == 168 { next }
  a == 192 && b == 0 && (c == 0 || c == 2) { next }
  a == 198 && (b == 18 || b == 19) { next }
  a == 198 && b == 51 && c == 100 { next }
  a == 203 && b == 0 && c == 113 { next }
  !($0 in ok)')
if [ -n "$bad" ]; then
  for ip in $bad; do grep -rnaF "$ip" "$tree" | sed "s|^$tree/||"; done
  die "public IPv4 address(es) not covered by a scrub or allow-ip rule: $(echo $bad)"
fi

# Gate 3: gitleaks on the exported files.
gitleaks dir --no-banner --redact --exit-code 1 "$tree" || die "gitleaks flagged the export"

mv "$tree" "$out"
echo "export ok: $(find "$out" -type f | wc -l) files from $(git -C "$repo" rev-parse --short HEAD)"
