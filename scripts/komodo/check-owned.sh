#!/usr/bin/env bash
# komodo/owned-stacks and the reconcile-owned Procedure in komodo/resources.toml must name the same
# stacks, each a [[stack]] there, as plain names. A wildcard or regex would also match Stacks never
# deployed, which DeployStackIfChanged treats as changed. Run by compose-validate; runnable by hand.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/komodo/lib.sh
. scripts/komodo/lib.sh
toml=komodo/resources.toml
fail=0
err() { echo "::error file=$1::$2"; fail=1; }

n=$(grep -c '^name = "reconcile-owned"$' "$toml" || true)
[ "$n" = 1 ] || { err "$toml" "expected exactly one reconcile-owned Procedure, found $n"; exit 1; }

# From the Procedure's name line to the next top-level [[...]] that is not one of its stages.
block=$(awk '
  /^name = "reconcile-owned"$/ { on = 1; next }
  on && /^\[\[/ && $0 != "[[procedure.config.stage]]" { on = 0 }
  on' "$toml")
execs=$(printf '%s\n' "$block" | grep -c 'execution\.type' || true)
line=$(printf '%s\n' "$block" | grep 'execution\.type = "BatchDeployStackIfChanged"' || true)
if [ "$execs" != 1 ] || [ -z "$line" ]; then
  err "$toml" "reconcile-owned must hold exactly one execution, BatchDeployStackIfChanged (found $execs)"
  exit 1
fi
printf '%s\n' "$line" | grep -q 'execution\.params\.pattern = "[^"]*"' \
  || { err "$toml" "reconcile-owned: pattern must be a one-line \"...\" string"; exit 1; }
pattern=$(printf '%s\n' "$line" | sed -n 's/.*execution\.params\.pattern = "\([^"]*\)".*/\1/p')
case "$pattern" in
  *[!a-z0-9,\ -]*) err "$toml" "reconcile-owned pattern holds something other than plain stack names: '$pattern'" ;;
esac
printf '%s\n' "$line" | grep -q 'tags' && err "$toml" "reconcile-owned must not filter by tags"

in_pattern=$(printf '%s' "$pattern" | tr ',' '\n' | tr -d ' ' | sed '/^$/d' | sort)
owned=$(komodo_owned | sort)
stacks=$(awk 'prev == "[[stack]]" { print } { prev = $0 }' "$toml" | sed -n 's/^name = "\(.*\)"$/\1/p' | sort)

dups=$(printf '%s\n' "$owned" | sed '/^$/d' | uniq -d)
[ -z "$dups" ] || err komodo/owned-stacks "listed twice: $(echo $dups)"
if [ "$in_pattern" != "$owned" ]; then
  err "$toml" "reconcile-owned pattern [$(echo $in_pattern)] differs from komodo/owned-stacks [$(echo $owned)]"
fi
for s in $owned; do
  printf '%s\n' "$stacks" | grep -qxF -- "$s" || err komodo/owned-stacks "'$s' is not a [[stack]] in $toml"
done

[ "$fail" = 0 ] && echo "OK: komodo/owned-stacks and reconcile-owned agree ($(printf '%s\n' "$owned" | sed '/^$/d' | wc -l) stack(s))"
exit $fail
