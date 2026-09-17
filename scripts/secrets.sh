#!/usr/bin/env bash
# Encrypted secret sync: plaintext in gitignored secrets/, ciphertext in the
# committed secrets.enc/. Commands + model: docs/runbooks/setup-operations/secret-sync.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLAIN_DIR="$REPO_ROOT/secrets/portainer-env"          # gitignored plaintext (device-local source of truth)
ENC_DIR="$REPO_ROOT/secrets.enc/portainer-env"        # committed ciphertext
SSH_PLAIN_DIR="$REPO_ROOT/secrets/ssh"                # gitignored plaintext SSH keys (truenas + vps)
SSH_ENC_DIR="$REPO_ROOT/secrets.enc/ssh"              # committed ciphertext SSH keys
KEY_PLAIN="$REPO_ROOT/secrets/age-key.txt"            # gitignored private identity (this device)
KEY_ENC="$REPO_ROOT/secrets.enc/age-key.age"          # committed, passphrase-wrapped identity
RECIPIENT_FILE="$REPO_ROOT/secrets.enc/age-recipient.txt"  # committed public key
BIN_DIR="$REPO_ROOT/scripts/.bin"                     # gitignored age binaries (auto-bootstrapped)
AGE_VERSION="v1.2.1"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()    { c_red "error: $*" >&2; exit 1; }

# --- locate age / age-keygen, bootstrapping a pinned static binary if absent -------
find_age() {
  if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    AGE="$(command -v age)"; KEYGEN="$(command -v age-keygen)"; return
  fi
  if [ -x "$BIN_DIR/age" ] && [ -x "$BIN_DIR/age-keygen" ]; then
    AGE="$BIN_DIR/age"; KEYGEN="$BIN_DIR/age-keygen"; return
  fi
  c_ylw "age not found — downloading pinned static binary ($AGE_VERSION) to scripts/.bin/ ..."
  local arch a os
  arch="$(uname -m)"; os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$arch" in x86_64) a=amd64;; aarch64|arm64) a=arm64;; *) a="$arch";; esac
  case "$os" in linux|darwin) ;; *) die "unsupported OS '$os' — install age manually: https://github.com/FiloSottile/age";; esac
  mkdir -p "$BIN_DIR"
  local url="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${os}-${a}.tar.gz"
  command -v curl >/dev/null 2>&1 || die "need curl to bootstrap age (or install age yourself)"
  curl -fsSL "$url" | tar xz -C "$BIN_DIR" --strip-components=1 age/age age/age-keygen \
    || die "failed to download age from $url"
  chmod +x "$BIN_DIR/age" "$BIN_DIR/age-keygen"
  AGE="$BIN_DIR/age"; KEYGEN="$BIN_DIR/age-keygen"
  c_grn "age ready: $($AGE --version)"
}

recipient() {  # echo the public key, from the committed file or by deriving from the local key
  if [ -s "$RECIPIENT_FILE" ]; then cat "$RECIPIENT_FILE"; return; fi
  [ -s "$KEY_PLAIN" ] || die "no recipient file and no local key — run 'secrets.sh unlock' or 'init' first"
  "$KEYGEN" -y "$KEY_PLAIN"
}

ensure_local_key() {  # make sure the plaintext private key exists on this device (via passphrase)
  [ -s "$KEY_PLAIN" ] && return
  [ -s "$KEY_ENC" ] || die "no key on this device and no committed key ($KEY_ENC) — run 'init' on your first device"
  c_ylw "unlocking your age key — enter your secrets passphrase:"
  mkdir -p "$(dirname "$KEY_PLAIN")"
  "$AGE" -d -o "$KEY_PLAIN" "$KEY_ENC" || die "wrong passphrase or corrupt key"
  chmod 600 "$KEY_PLAIN"
}

# --- commands ----------------------------------------------------------------------
cmd_init() {
  [ -s "$KEY_ENC" ] && die "already initialised ($KEY_ENC exists). Use 'unlock' on this device instead."
  find_age
  mkdir -p "$PLAIN_DIR" "$ENC_DIR" "$(dirname "$KEY_ENC")"
  # Resumable: age-keygen -o refuses to overwrite, so reuse a key left by a failed init.
  if [ -s "$KEY_PLAIN" ]; then
    c_ylw "Found an existing key from a previous run ($KEY_PLAIN) — reusing it (no new keypair)."
  else
    c_ylw "Generating a new age keypair (the master lock)..."
    "$KEYGEN" -o "$KEY_PLAIN"          # prints the public key to stderr; DON'T hide errors
    chmod 600 "$KEY_PLAIN"
  fi
  "$KEYGEN" -y "$KEY_PLAIN" > "$RECIPIENT_FILE"
  c_grn "public key: $(cat "$RECIPIENT_FILE")"
  echo
  c_ylw "Now choose your ONE passphrase. Use a STRONG one — it protects every secret and"
  c_ylw "the wrapped key is committed to git. A password manager entry is ideal."
  "$AGE" -p -o "$KEY_ENC" "$KEY_PLAIN" || die "passphrase wrap failed"
  echo
  cmd_lock
  c_grn "Initialised. Commit: secrets.enc/  (NEVER commit secrets/ — it's gitignored)."
  c_ylw "This key decrypts the WHOLE vault — every stack env and every host SSH key. It stays"
  c_ylw "on your workstation: never a GitHub secret, never on the runner. Push env with"
  c_ylw "'scripts/secrets.sh push <stack>' instead."
}

cmd_unlock() {
  find_age
  ensure_local_key
  local n=0
  shopt -s nullglob
  mkdir -p "$PLAIN_DIR"
  for enc in "$ENC_DIR"/*.env.age; do
    local base name plain
    base="$(basename "$enc")"; name="${base%.age}"; plain="$PLAIN_DIR/$name"
    "$AGE" -d -i "$KEY_PLAIN" -o "$plain" "$enc"
    chmod 600 "$plain"; n=$((n+1))
  done
  # SSH keys (truenas + vps) — any filename, same age identity.
  mkdir -p "$SSH_PLAIN_DIR"
  for enc in "$SSH_ENC_DIR"/*.age; do
    local base name plain
    base="$(basename "$enc")"; name="${base%.age}"; plain="$SSH_PLAIN_DIR/$name"
    "$AGE" -d -i "$KEY_PLAIN" -o "$plain" "$enc"
    chmod 600 "$plain"; n=$((n+1))
  done
  shopt -u nullglob
  c_grn "unlocked $n secret file(s) -> secrets/  (SSH keys in $SSH_PLAIN_DIR — copy to ~/.ssh to use)"
}

cmd_lock() {
  find_age
  local rcpt; rcpt="$(recipient)"
  mkdir -p "$ENC_DIR"
  local n=0
  shopt -s nullglob
  for plain in "$PLAIN_DIR"/*.env; do
    local base enc
    base="$(basename "$plain")"; enc="$ENC_DIR/$base.age"
    "$AGE" -r "$rcpt" -o "$enc" "$plain"
    n=$((n+1))
  done
  # SSH keys (truenas + vps) — encrypt every plaintext file in secrets/ssh/.
  if [ -d "$SSH_PLAIN_DIR" ]; then
    mkdir -p "$SSH_ENC_DIR"
    for plain in "$SSH_PLAIN_DIR"/*; do
      [ -f "$plain" ] || continue
      local base enc
      base="$(basename "$plain")"; enc="$SSH_ENC_DIR/$base.age"
      "$AGE" -r "$rcpt" -o "$enc" "$plain"
      n=$((n+1))
    done
  fi
  shopt -u nullglob
  [ "$n" -eq 0 ] && c_ylw "no plaintext secrets to lock" || c_grn "locked $n secret file(s) -> secrets.enc/"
}

cmd_edit() {
  [ $# -ge 1 ] || die "usage: secrets.sh edit <stack>   (e.g. secrets.sh edit mealie)"
  find_age
  ensure_local_key >/dev/null 2>&1 || true
  local stack="$1" plain="$PLAIN_DIR/$1.env" enc="$ENC_DIR/$1.env.age"
  mkdir -p "$PLAIN_DIR"
  if [ ! -s "$plain" ] && [ -s "$enc" ]; then
    ensure_local_key
    "$AGE" -d -i "$KEY_PLAIN" -o "$plain" "$enc"
  fi
  "${EDITOR:-nano}" "$plain"
  local rcpt; rcpt="$(recipient)"
  "$AGE" -r "$rcpt" -o "$enc" "$plain"
  c_grn "re-locked $stack -> $enc  (git add $enc && commit)"
}

# KEY=VALUE -> a JSON array of {name, value}. Splits on the FIRST '=' so values may contain
# '='; strips a trailing CR.
env_array() {  # env_array <stack> -> JSON array on stdout
  local enc="$ENC_DIR/$1.env.age"
  [ -f "$enc" ] || { echo '[]'; return 0; }
  "$AGE" -d -i "$KEY_PLAIN" "$enc" | jq -Rn '
    [ inputs
      | select(test("^[[:space:]]*#")|not)
      | select(test("="))
      | capture("^(?<name>[^=]+)=(?<value>.*)$")
      | {name: (.name|gsub("^\\s+|\\s+$";"")), value: (.value|rtrimstr("\r"))}
    ]'
}

# --- Komodo Variables: workstation-only, like push -------------------------------------
# komodo/resources.toml gives each Stack its env as KEY=[[<STACK>__<KEY>]] (komodo-migration.md §4).
# komodo-vars writes exactly the Variables it references, from the vault. Docs: secret-sync.md
KOMODO_TOML="$REPO_ROOT/komodo/resources.toml"
# Identifiers, not secrets. A secret Variable is masked everywhere in Komodo's deploy logs, so a short
# common value garbles them (F18). Every key not named here is written as a secret.
KOMODO_NON_SECRET="AUTHENTIK__AUTHENTIK_IMAGE AUTHENTIK__AUTHENTIK_TAG AUTHENTIK__COMPOSE_PORT_HTTP AUTHENTIK__COMPOSE_PORT_HTTPS"
# shellcheck source=scripts/komodo/lib.sh
. "$REPO_ROOT/scripts/komodo/lib.sh"

komodo_prefix() { printf '%s__' "$1" | tr 'a-z-' 'A-Z_'; }   # a1-vps-ntp -> A1_VPS_NTP__

load_komodo_conf() {  # the admin API key, from the vault's komodo.env; never exported or printed
  local enc="$ENC_DIR/komodo.env.age" env
  [ -f "$enc" ] || die "no $enc: the Komodo API key lives there"
  env="$("$AGE" -d -i "$KEY_PLAIN" "$enc")"
  KOMODO_API_KEY="$(printf '%s\n' "$env" | sed -n 's/^KOMODO_API_KEY=//p' | tr -d '\r')"
  KOMODO_API_SECRET="$(printf '%s\n' "$env" | sed -n 's/^KOMODO_API_SECRET=//p' | tr -d '\r')"
  [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ] || die "KOMODO_API_KEY / KOMODO_API_SECRET missing from $enc"
  KOMODO_URL="${KOMODO_URL:-https://komodo.example.com}"   # LAN-only
}

toml_stack_names() {
  awk 'prev == "[[stack]]" { print } { prev = $0 }' "$KOMODO_TOML" | sed -n 's/^name = "\(.*\)"$/\1/p'
}

toml_stack_refs() {  # toml_stack_refs <stack> -> the Variable names its [[stack]] entry references
  awk -v n="name = \"$1\"" '/^\[\[/ { on = 0 } prev == "[[stack]]" && $0 == n { on = 1 } { prev = $0 } on' "$KOMODO_TOML" \
    | { grep -oE '\[\[[A-Z0-9_]+__[A-Z0-9_]+\]\]' || true; } | tr -d '[]' | sort -u
}

# komodo_plan <stack> <env-json> <variables-json> -> "ACTION NAME IS_SECRET" lines, never a value.
# Values enter jq on file descriptors, not argv, and only ever get compared.
komodo_plan() {
  local pfx refs
  pfx="$(komodo_prefix "$1")"; refs="$(toml_stack_refs "$1")"
  jq -rn --arg pfx "$pfx" --arg refs "$refs" --arg plain "$KOMODO_NON_SECRET" \
    --slurpfile env <(printf '%s' "$2") --slurpfile have <(printf '%s' "$3") '
    ($env[0] | map({key: ($pfx + .name), value: .value}) | from_entries) as $want
    | ($have[0] | map({key: .name, value: .}) | from_entries) as $cur
    | ($refs | split("\n") | map(select(. != ""))) as $r
    | ($plain | split(" ")) as $p
    | ( $r[] as $n
        | if ($n | startswith($pfx) | not) then "BADPREFIX \($n) -"
          elif $want[$n] == null then "MISSING \($n) -"
          else ($p | any(. == $n) | not) as $sec
            | if $cur[$n] == null then "CREATE \($n) \($sec)"
              else [ (if $cur[$n].is_secret != $sec then "FLAG \($n) \($sec)" else empty end),
                     (if $cur[$n].value != $want[$n] then "VALUE \($n) \($sec)" else empty end) ]
                   | if length == 0 then "UNCHANGED \($n) \($sec)" else .[] end
              end
          end ),
      ( $want | keys[] | select(. as $k | $r | any(. == $k) | not) | "UNREFERENCED \(.) -" ),
      ( $cur | keys[] | select(startswith($pfx)) | select(. as $k | $r | any(. == $k) | not) | "ORPHAN \(.) -" )'
}

komodo_var_body() {  # komodo_var_body <env-json> <prefix> <name> <jq object using $n and $v>
  printf '%s' "$1" | jq -c --arg pfx "$2" --arg n "$3" "(map(select((\$pfx + .name) == \$n)) | first | .value) as \$v | $4"
}

komodo_vars_one() {  # komodo_vars_one <stack> <dry true|false> <variables-json>
  local s="$1" dry="$2" have="$3" pfx env_json plan act n sec bad=0 would=""
  toml_stack_names | grep -qxF -- "$s" || { c_red "$s: no [[stack]] named $s in komodo/resources.toml"; return 1; }
  pfx="$(komodo_prefix "$s")"
  env_json="$(env_array "$s")"
  plan="$(komodo_plan "$s" "$env_json" "$have")" || { c_red "$s: could not compare the vault with Komodo"; return 1; }
  [ "$dry" = true ] && would="would "
  while read -r act n sec; do
    case "$act" in
      BADPREFIX)    c_red "$s: resources.toml references $n, which does not start with $pfx"; bad=1 ;;
      MISSING)      c_red "$s: resources.toml references $n, but $s.env in the vault has no ${n#"$pfx"}"; bad=1 ;;
      UNREFERENCED) c_ylw "$s: ${n#"$pfx"} is in the vault, but nothing references $n. Not written" ;;
      ORPHAN)       c_ylw "$s: Komodo has $n, which resources.toml no longer references. Left alone" ;;
    esac
  done <<< "$plan"
  [ "$bad" = 0 ] || return 1
  [ -n "$plan" ] || { echo "$s: references no Variables"; return 0; }
  echo "$s:"
  # Secret first, value second, plain last: a value is never written while its Variable is plain
  # on its way to secret. (Komodo's own update log records the new value either way, F19.)
  while read -r act n sec; do
    [ "$act" = FLAG ] && [ "$sec" = true ] || continue
    echo "  ${would}mark $n secret"
    [ "$dry" = true ] || kapi write/UpdateVariableIsSecret "$(jq -nc --arg n "$n" '{name:$n, is_secret:true}')" >/dev/null || bad=1
  done <<< "$plan"
  while read -r act n sec; do
    local kind=plain; [ "$sec" = true ] && kind=secret
    case "$act" in
      UNCHANGED) echo "  unchanged $n ($kind)" ;;
      CREATE)
        echo "  ${would}create $n ($kind)"
        [ "$dry" = true ] || kapi write/CreateVariable \
          "$(komodo_var_body "$env_json" "$pfx" "$n" "{name:\$n, value:\$v, description:\"$s stack env, from the vault\", is_secret:$sec}")" >/dev/null || bad=1 ;;
      VALUE)
        echo "  ${would}update the value of $n ($kind)"
        [ "$dry" = true ] || kapi write/UpdateVariableValue "$(komodo_var_body "$env_json" "$pfx" "$n" '{name:$n, value:$v}')" >/dev/null || bad=1 ;;
    esac
  done <<< "$plan"
  while read -r act n sec; do
    [ "$act" = FLAG ] && [ "$sec" = false ] || continue
    echo "  ${would}mark $n plain"
    [ "$dry" = true ] || kapi write/UpdateVariableIsSecret "$(jq -nc --arg n "$n" '{name:$n, is_secret:false}')" >/dev/null || bad=1
  done <<< "$plan"
  return $bad
}

cmd_komodo_vars() {
  local dry=false
  [ "${1:-}" = "--dry-run" ] && { dry=true; shift; }
  [ $# -ge 1 ] || die "usage: secrets.sh komodo-vars [--dry-run] <stack>... | --all"
  command -v jq >/dev/null 2>&1 || die "need jq"
  [ -f "$KOMODO_TOML" ] || die "no $KOMODO_TOML"
  find_age
  ensure_local_key
  local stacks=() s
  if [ "$1" = "--all" ]; then mapfile -t stacks < <(toml_stack_names); else stacks=("$@"); fi
  for s in "${stacks[@]}"; do  # same guard as push: the ciphertext is what gets written
    if [ -f "$PLAIN_DIR/$s.env" ] && [ -f "$ENC_DIR/$s.env.age" ] && [ "$PLAIN_DIR/$s.env" -nt "$ENC_DIR/$s.env.age" ]; then
      die "$s: plaintext is newer than the ciphertext. Run 'secrets.sh edit $s' or 'lock' first"
    fi
  done
  load_komodo_conf
  local have fail=0
  have="$(kapi read/ListVariables)" || die "cannot list Komodo Variables at $KOMODO_URL"
  for s in "${stacks[@]}"; do komodo_vars_one "$s" "$dry" "$have" || fail=1; done
  return $fail
}

cmd_push() {
  [ $# -ge 1 ] || die "usage: secrets.sh push <stack>... | --all   (see docs/runbooks/setup-operations/secret-sync.md)"
  command -v jq >/dev/null 2>&1 || die "need jq"
  find_age
  ensure_local_key

  local stacks=() all=false
  if [ "$1" = "--all" ]; then
    all=true
    shopt -s nullglob
    local f
    for f in "$ENC_DIR"/*.env.age; do f="$(basename "$f")"; stacks+=("${f%.env.age}"); done
    shopt -u nullglob
    [ "${#stacks[@]}" -gt 0 ] || die "no encrypted env files in $ENC_DIR"
  else
    stacks=("$@")
  fi

  # Pushes the CIPHERTEXT — what you push is what you commit. An unlocked edit is stale.
  local s
  for s in "${stacks[@]}"; do
    [ -f "$ENC_DIR/$s.env.age" ] || die "no $ENC_DIR/$s.env.age — run 'secrets.sh lock' first"
    if [ -f "$PLAIN_DIR/$s.env" ] && [ "$PLAIN_DIR/$s.env" -nt "$ENC_DIR/$s.env.age" ]; then
      die "$s: plaintext is newer than the ciphertext — run 'secrets.sh lock' first"
    fi
  done
  load_komodo_conf

  # Komodo is the only control plane: push writes a stack's Variables, then deploys it.
  local fail=0 have
  have="$(kapi read/ListVariables)" || die "cannot list Komodo Variables at $KOMODO_URL"
  for s in "${stacks[@]}"; do
    if ! is_komodo_owned "$s"; then
      # komodo itself and the hand-applied stacks are not in owned-stacks; --all skips them.
      if [ "$all" = true ]; then c_ylw "skip $s (not in komodo/owned-stacks)"; continue; fi
      c_red "$s is not in komodo/owned-stacks, so push does not deploy it. For komodo or github-runner: 'komodo-vars $s', then Deploy in the UI"
      fail=1; continue
    fi
    if ! komodo_stack_exists "$s"; then
      c_red "$s has no Komodo Stack yet. Run 'secrets.sh komodo-vars $s', then merge its PR: deploy-stacks creates it"
      fail=1; continue
    fi
    c_ylw "push $s through Komodo (Variables, then DeployStack)"
    if komodo_vars_one "$s" false "$have" && komodo_deploy "$s"; then
      c_grn "OK: $s Variables written + deployed through Komodo"
      have="$(kapi read/ListVariables)" || die "cannot list Komodo Variables at $KOMODO_URL"
    else
      c_red "Komodo push failed for $s"; fail=1
    fi
  done
  return $fail
}

cmd_status() {
  find_age >/dev/null 2>&1 || true
  printf '%-16s %-10s %-10s %s\n' STACK PLAINTEXT CIPHERTEXT SYNC
  printf '%-16s %-10s %-10s %s\n' ---------------- --------- ---------- ----
  shopt -s nullglob
  local names=() f
  for f in "$PLAIN_DIR"/*.env "$ENC_DIR"/*.env.age; do
    local b; b="$(basename "$f")"; b="${b%.age}"; b="${b%.env}"; names+=("$b")
  done
  shopt -u nullglob
  local uniq; uniq="$(printf '%s\n' "${names[@]:-}" | sort -u | sed '/^$/d')"
  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    local p="$PLAIN_DIR/$s.env" e="$ENC_DIR/$s.env.age" pf="-" ef="-" sync="-"
    [ -f "$p" ] && pf="yes"; [ -f "$e" ] && ef="yes"
    if [ -f "$p" ] && [ -f "$e" ]; then
      if [ "$p" -nt "$e" ]; then sync="$(c_ylw 'plaintext newer -> run lock')"; else sync="ok"; fi
    elif [ -f "$e" ]; then sync="encrypted only -> run unlock"
    elif [ -f "$p" ]; then sync="$(c_ylw 'not encrypted -> run lock')"; fi
    printf '%-16s %-10s %-10s %s\n' "$s" "$pf" "$ef" "$sync"
  done <<< "$uniq"

  # SSH keys (truenas + vps), keyed by full filename rather than a stripped stack name.
  shopt -s nullglob
  local snames=() sfile
  for sfile in "$SSH_PLAIN_DIR"/* "$SSH_ENC_DIR"/*.age; do
    [ -f "$sfile" ] || continue
    local sb; sb="$(basename "$sfile")"; sb="${sb%.age}"; snames+=("$sb")
  done
  shopt -u nullglob
  if [ "${#snames[@]}" -gt 0 ]; then
    local suniq; suniq="$(printf '%s\n' "${snames[@]}" | sort -u | sed '/^$/d')"
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      local p="$SSH_PLAIN_DIR/$s" e="$SSH_ENC_DIR/$s.age" pf="-" ef="-" sync="-"
      [ -f "$p" ] && pf="yes"; [ -f "$e" ] && ef="yes"
      if [ -f "$p" ] && [ -f "$e" ]; then
        if [ "$p" -nt "$e" ]; then sync="$(c_ylw 'plaintext newer -> run lock')"; else sync="ok"; fi
      elif [ -f "$e" ]; then sync="encrypted only -> run unlock"
      elif [ -f "$p" ]; then sync="$(c_ylw 'not encrypted -> run lock')"; fi
      printf '%-20s %-10s %-10s %s\n' "$s" "$pf" "$ef" "$sync"
    done <<< "$suniq"
  fi
}

case "${1:-}" in
  init)   cmd_init ;;
  unlock) cmd_unlock ;;
  lock)   cmd_lock ;;
  edit)   shift; cmd_edit "$@" ;;
  push)   shift; cmd_push "$@" ;;
  komodo-vars) shift; cmd_komodo_vars "$@" ;;
  status) cmd_status ;;
  *) cat >&2 <<EOF
secrets.sh — encrypted secret sync (age, one passphrase). See docs/runbooks/setup-operations/secret-sync.md

  scripts/secrets.sh init      first device: create key, set passphrase, encrypt existing env
  scripts/secrets.sh unlock    after clone on a new device: passphrase -> decrypt all env
  scripts/secrets.sh lock      encrypt plaintext env after editing (no passphrase)
  scripts/secrets.sh edit <s>  edit one stack's env then re-lock it
  scripts/secrets.sh push <s>… write an owned stack's Komodo Variables from the vault, then
                               deploy it through Komodo (--all: every owned stack in the vault)
  scripts/secrets.sh komodo-vars [--dry-run] <s>…|--all
                               write the [[STACK__KEY]] Variables komodo/resources.toml references
  scripts/secrets.sh status    show plaintext/ciphertext drift
EOF
     exit 2 ;;
esac
