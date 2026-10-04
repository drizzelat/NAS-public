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
for f in scrub.sed checks strip allow-path allow-ip allow-domain allow-email; do : >"$tmp/$f"; done
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
    strip) printf '%s\n' "$arg" >>"$tmp/strip" ;;
    allow-path | allow-ip | allow-domain | allow-email) printf '%s\n' "$arg" >>"$tmp/$kind" ;;
    *) die "rules: unknown kind '$kind'" ;;
  esac
done <"$rules"

for p in "${excludes[@]}"; do
  [ -e "$tree/$p" ] || die "rules: excluded path '$p' is not in the repo any more"
  rm -rf "${tree:?}/$p"
done

# strip <path> <start ERE> => <end ERE> => <replacement line>: a block of a published file that stays private.
# From the first line matching <start> up to, not including, the first later line matching <end>, the file gets
# the replacement line instead. Fails closed: a start or end that no longer matches means the file was
# restructured and the block may now be published, so nothing is exported until the rule is updated.
while IFS= read -r line; do
  path=${line%% *} rest=${line#* }
  start=${rest%% => *} rest=${rest#* => }
  end=${rest%% => *} note=${rest#* => }
  [ -f "$tree/$path" ] || die "rules: strip path '$path' is not in the repo any more"
  S=$start E=$end N=$note awk '
    st == 0 && $0 ~ ENVIRON["S"] { st = 1; print ENVIRON["N"]; next }
    st == 1 { if ($0 ~ ENVIRON["E"]) { st = 2; print } ; next }
    { print }
    END { exit st == 2 ? 0 : 1 }' "$tree/$path" >"$tmp/stripped" \
    || die "rules: strip block in '$path' not found (start '$start', end '$end')"
  cat "$tmp/stripped" >"$tree/$path"
done <"$tmp/strip"

# Only listed paths are published. A new top-level entry fails the export until someone decides. One
# that is listed only through a nested allow-path (docs/services) is published in part: the rest of it
# stays private, so a new doc is never published until it is named.
while IFS= read -r p; do
  case $p in */*) [ -e "$tree/$p" ] || die "rules: allow-path '$p' is not in the repo any more" ;; esac
done <"$tmp/allow-path"
partial=()
while IFS= read -r entry; do
  grep -qxF -- "$entry" "$tmp/allow-path" && continue
  awk -v p="$entry/" 'index($0, p) == 1 { f = 1 } END { exit !f }' "$tmp/allow-path" \
    || die "top-level '$entry' is neither allow-path nor exclude in the rules"
  partial+=("$entry")
done < <(find "$tree" -mindepth 1 -maxdepth 1 -printf '%f\n')
for entry in ${partial[@]+"${partial[@]}"}; do
  while IFS= read -r f; do
    awk -v f="$f" '$0 == f || index(f, $0 "/") == 1 { ok = 1 } END { exit !ok }' "$tmp/allow-path" \
      || rm -f -- "${tree:?}/$f"
  done < <(cd "$tree" && find "$entry" -type f)
  find "$tree/$entry" -type d -empty -delete
done

{
  cat <<'EOF'
> **Public mirror.** A sanitized, read-only copy of a private homelab repo, synced weekly.
> Secrets, the encrypted vault and some internal docs are left out; domains, public IPs, SSH keys
> and personal details are replaced with example values, so nothing here deploys as-is.
> Links to pull requests and removed files do not resolve.

EOF
  cat "$tree/README.md"
} >"$tmp/README.md"
mv "$tmp/README.md" "$tree/README.md"

find "$tree" -type f -exec grep -IlZ '' {} + | xargs -0 -r sed -E -i -f "$tmp/scrub.sed"

# Print every file:line holding one of the fixed strings on stdin.
show() { while IFS= read -r s; do grep -rnaiF -- "$s" "$tree" | sed "s|^$tree/||" | head -n 5; done; }

# Gate 1: no scrub or deny pattern may survive, in contents or in paths.
if grep -rnaiE -f "$tmp/checks" "$tree" | sed "s|^$tree/||"; then
  die "a scrub or deny pattern still matches (above)"
fi
if (cd "$tree" && find . | grep -iE -f "$tmp/checks"); then
  die "a scrub or deny pattern matches a path (above)"
fi

# Gate 2: every IPv4 token is private, CGNAT, documentation, special-use or allow-ip.
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
  echo "$bad" | show
  die "public IPv4 address(es) without a scrub or allow-ip rule: $(echo $bad)"
fi

# Gate 3: every domain's last two labels are allow-domain. TLDs that double as file extensions
# (sh, md, py) or code identifiers (name, email, host) are left out; each would flag half the repo.
tlds='com|net|org|io|dev|app|ai|me|co|xyz|info|biz|cloud|online|site|tech|page|link|space|website|network|systems|family|tv|gg|fm|cc|ws|to|im|pw|tk'
tlds+='|de|at|ch|eu|uk|nl|fr|it|es|se|no|dk|fi|be|lu|cz|pl|pt|ie|li|is|lt|lv|ee|hu|ro|sk|si|hr|gr|us|ca|au|jp|ru|cn|in|br'
bad=$(grep -rhoaiE "\b([a-z0-9-]+\.)+($tlds)\b" "$tree" | tr 'A-Z' 'a-z' | sort -u | awk -F. -v allow="$tmp/allow-domain" '
  BEGIN { while ((getline x < allow) > 0) ok[x] = 1 }
  !(($(NF - 1) "." $NF) in ok)')
if [ -n "$bad" ]; then
  echo "$bad" | show
  die "domain(s) without a scrub or allow-domain rule: $(echo $bad)"
fi

# Gate 4: every email address is on an allow-email domain.
bad=$(grep -rhoaE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$tree" | sort -u | awk -F@ -v allow="$tmp/allow-email" '
  BEGIN { while ((getline x < allow) > 0) ok[x] = 1 }
  { dom = tolower($2); hit = 0
    for (a in ok) if (dom == a || substr(dom, length(dom) - length(a)) == "." a) hit = 1
    if (!hit) print }')
if [ -n "$bad" ]; then
  echo "$bad" | show
  die "email address(es) without a scrub or allow-email rule: $(echo $bad)"
fi

# Gate 5: gitleaks on the exported files.
gitleaks dir --no-banner --redact --exit-code 1 "$tree" || die "gitleaks flagged the export"

mv "$tree" "$out"
echo "export ok: $(find "$out" -type f | wc -l) files from $(git -C "$repo" rev-parse --short HEAD)"
