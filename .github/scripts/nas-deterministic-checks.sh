#!/usr/bin/env bash
# The yes/no half of the nightly health check, with no model in the loop: snapshot
# recency and retention, scrub age, dump freshness, cert expiry, auto-pull clone,
# boot-guard drop-in, Storage Box snapshots.
# Prints PASS/FAIL/WARN/SKIP lines; exits 1 on any FAIL.
# Docs: docs/runbooks/setup-operations/deploy-state-probe.md
set -euo pipefail

nas="${1:?usage: nas-deterministic-checks.sh <nas-lan-ip>}"
: "${NAS_SSH_KEY_FILE:?}"
[[ -d stacks ]] || { echo "run from the repo root" >&2; exit 2; }

# Cadences and retentions are the ones documented in docs/scheduled-tasks.md; a change
# there is a change here. Hours unless the name says days.
# One line per snapshot task tier: naming-schema prefix | datasets | cadence h | retention d.
SNAP_TIERS=(
  "auto|apps|4|3"
  "auto|data/smb_share data/immich data/paperless|24|14"
  "daily|apps|24|14"
  "weekly|apps data/smb_share data/immich data/paperless|168|56"
  "monthly|apps data/smb_share data/immich data/paperless|744|186"
)
SLACK_H=2           # cadence + 2 h for hourly/daily jobs (the checklist's freshness rule)
SCRUB_MAX_D=40      # 35-day scrub threshold + 5 days of slack
DUMP_CADENCE_H=24
LEAKED_SNAP_D=2     # a cloud-sync temp snapshot older than this was left behind
STORAGEBOX_MAX_H=36
STORAGEBOX_MIN_COUNT=8
# Kept on purpose until a decision, never a leaked-snapshot warning (docs/roadmap.md).
KEEP_SNAPSHOTS="apps/npm@pre-caddy-2026-09-06 apps/portainer@pre-removal-2026-09-17"

fails=0
report=""
say() { echo "$1"; report+="$1"$'\n'; }
fail() { say "FAIL  $*"; fails=$((fails + 1)); }
pass() { say "PASS  $*"; }
warn() { say "WARN  $*"; }
skip() { say "SKIP  $*"; }

probe() {
  ssh -i "$NAS_SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "nashealth@$nas" "$@"
}

now="$(date +%s)"
hours_since() { echo $(((now - $1) / 3600)); }

# --- 1/2. Snapshot recency and retention -------------------------------------------
before=$fails
if ! snaps="$(probe snapshots)"; then
  fail "snapshots: verb failed, recency and retention unchecked"
else
  declare -A newest=() oldest=()
  leaked=""
  while IFS=$'\t' read -r name created; do
    [[ -n "$name" ]] || continue
    # -p gives epoch seconds; anything else is an older host probe, caught below.
    [[ "$created" =~ ^[0-9]+$ ]] || continue
    # boot-pool holds TrueNAS's own boot-environment snapshots (@pristine and friends),
    # which are permanent by design and are not this estate's to prune.
    [[ "$name" != boot-pool/* ]] || continue
    ds="${name%@*}"
    snap="${name#*@}"
    tier="${snap%%-*}"
    if [[ "$tier" =~ ^(auto|daily|weekly|monthly)$ && "$snap" == "$tier"-[0-9]* ]]; then
      k="$ds|$tier"
      [[ -z "${newest[$k]:-}" || $created -gt ${newest[$k]} ]] && newest["$k"]=$created
      [[ -z "${oldest[$k]:-}" || $created -lt ${oldest[$k]} ]] && oldest["$k"]=$created
    elif [[ "$snap" != cloud_sync-* ]] || (( (now - created) / 86400 >= LEAKED_SNAP_D )); then
      [[ " $KEEP_SNAPSHOTS " == *" $name "* ]] || \
        { (( (now - created) / 86400 >= LEAKED_SNAP_D )) && leaked+="$name "; }
    fi
  done <<<"$snaps"
  # Epoch creation times come from the -p flag; without it nothing parses as a number.
  (( ${#newest[@]} > 0 )) || fail "snapshots: no dataset parsed — re-install scripts/nas-health-probe.sh on the NAS"

  ntier=0
  for t in "${SNAP_TIERS[@]}"; do
    IFS='|' read -r tier dss cad ret <<<"$t"
    for ds in $dss; do
      ntier=$((ntier + 1))
      k="$ds|$tier"
      if [[ -z "${newest[$k]:-}" ]]; then
        fail "snapshot recency: $ds has no $tier-* snapshot at all"
        continue
      fi
      age="$(hours_since "${newest[$k]}")"
      (( age <= cad + SLACK_H )) || fail "snapshot recency: newest $tier-* on $ds is ${age}h old, cadence ${cad}h + ${SLACK_H}h slack"
      oage=$(( (now - oldest[$k]) / 86400 ))
      (( oage <= ret + 1 )) || fail "snapshot retention: oldest $tier-* on $ds is ${oage}d old, retention ${ret}d + 1d — pruning stopped"
    done
  done
  [[ -z "$leaked" ]] || warn "leaked snapshots older than ${LEAKED_SNAP_D}d: $leaked"
  if [[ $fails -eq $before ]]; then
    pass "snapshots: $ntier dataset tier(s) within cadence and retention"
  fi
fi

# --- 3. Scrub age -------------------------------------------------------------------
before=$fails
if ! pools="$(probe pools)"; then
  fail "scrub age: pools verb failed"
else
  pool=""
  pools_seen=0
  checked=0
  # An error-only scrub (`zpool scrub -e`) prints "scrub:", a full one "scan:".
  while IFS= read -r line; do
    case "$line" in
      *"pool: "*)
        [[ -z "$pool" || $checked -eq $pools_seen ]] || fail "scrub age: pool $pool has no scrub line in zpool status"
        pool="${line##*pool: }"
        pools_seen=$((pools_seen + 1))
        ;;
      *"scan: "* | *"scrub: "*)
        [[ -n "$pool" ]] || continue
        case "$line" in
          *" on "*)
            when="${line##* on }"
            if ts="$(date -d "$when" +%s 2>/dev/null)"; then
              days=$(( (now - ts) / 86400 ))
              checked=$((checked + 1))
              (( days <= SCRUB_MAX_D )) || fail "scrub age: pool $pool last scrubbed ${days}d ago (threshold ${SCRUB_MAX_D}d)"
            else
              fail "scrub age: pool $pool — could not parse '$when'"
              checked=$((checked + 1))
            fi
            ;;
          *"in progress"*) checked=$((checked + 1)) ;;
          *) fail "scrub age: pool $pool has never been scrubbed ($line)"; checked=$((checked + 1)) ;;
        esac
        ;;
    esac
  done <<<"$pools"
  [[ -z "$pool" || $checked -eq $pools_seen ]] || fail "scrub age: pool $pool has no scrub line in zpool status"
  (( pools_seen > 0 )) || fail "scrub age: zpool status listed no pool"
  if [[ $fails -eq $before ]]; then pass "scrub age: $checked pool(s) scrubbed within ${SCRUB_MAX_D}d"; fi
fi

# --- 4. DB dump freshness and integrity ---------------------------------------------
# Expected (dir, database) pairs come from the nas.backup.* labels, exactly as
# pg-dump-backup.sh discovers its targets. Per DATABASE, not per directory: the A1's
# dir holds synapse AND mautrix_whatsapp, and until 2026-09-25 only the newest file in
# the dir was checked — so a night where just the bridge DB failed read as a clean pass.
before=$fails
# nas.backup.db (comma-separated) is always followed by nas.backup.dir in the same
# service block; awk pairs them and emits one "dir db" row per database.
mapfile -t want_pairs < <(
  awk '
    /nas\.backup\.db:/  { sub(/.*nas\.backup\.db:[[:space:]]*/, ""); gsub(/"/, ""); dbs = $0 }
    /nas\.backup\.dir:/ {
      sub(/.*nas\.backup\.dir:[[:space:]]*/, ""); gsub(/"/, "");
      if (dbs != "") { n = split(dbs, a, ","); for (i = 1; i <= n; i++) print $0, a[i]; dbs = "" }
    }
  ' stacks/*/docker-compose.yml | sort -u
)
mapfile -t dump_dirs < <(printf '%s\n' "${want_pairs[@]}" | awk '{print $1}' | sort -u)
if [[ ${#want_pairs[@]} -eq 0 ]]; then
  fail "dumps: no nas.backup.db/nas.backup.dir label pairs found in stacks/"
elif ! dumps="$(probe dumps "${dump_dirs[@]}")"; then
  fail "dumps: verb failed for ${dump_dirs[*]}"
else
  dir=""
  db=""
  seen_pairs=()
  while IFS= read -r line; do
    case "$line" in
      "=== "*" ===") dir="${line:4:${#line}-8}"; db="" ;;
      "--- db: "*" ---") db="${line:8:${#line}-12}" ;;
      "MISSING DIR") fail "dumps: $dir does not exist" ;;
      "no *.sql.gz"*) fail "dumps: $dir holds no dump${db:+ for $db}" ;;
      "mtime: "*)
        seen_pairs+=("$dir $db")
        age="$(hours_since "${line#mtime: }")"
        (( age <= DUMP_CADENCE_H + SLACK_H )) || fail "dumps: newest $db dump in $dir is ${age}h old (cadence ${DUMP_CADENCE_H}h + ${SLACK_H}h)"
        ;;
      "gzip -t: FAILED") fail "dumps: gzip -t failed on the newest $db dump in $dir" ;;
      "complete: MISSING") fail "dumps: newest $db dump in $dir carries no end marker — truncated" ;;
      "size: "*) newest_size="${line#size: }" ;;
      "sizes: "*)
        read -ra all <<<"${line#sizes: }"
        if [[ ${#all[@]} -gt 1 ]]; then
          median="$(printf '%s\n' "${all[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')"
          if (( newest_size * 2 < median || newest_size < 1024 )); then
            fail "dumps: newest $db dump in $dir is ${newest_size}B, under half the ${median}B median"
          elif (( newest_size * 10 < median * 8 )); then
            warn "dumps: newest $db dump in $dir is ${newest_size}B, under 80% of the ${median}B median"
          fi
        fi
        ;;
    esac
  done <<<"$dumps"
  # A labelled database that reported no mtime was never checked — either it has no dump
  # at all, or the host probe predates the per-database output and is reporting per dir.
  for want in "${want_pairs[@]}"; do
    found=0
    for got in ${seen_pairs[@]+"${seen_pairs[@]}"}; do [[ "$got" == "$want" ]] && { found=1; break; }; done
    (( found )) || fail "dumps: ${want#* } in ${want%% *} reported no mtime — no dump for it, or re-install scripts/nas-health-probe.sh on the NAS"
  done
  if [[ $fails -eq $before ]]; then pass "dumps: ${#want_pairs[@]} database(s) fresh, gzip-clean and complete"; fi
fi

# --- 5. On-host repo clone fresh ----------------------------------------------------
before=$fails
if ! head_remote="$(probe repo-head)"; then
  fail "repo clone: repo-head verb failed"
else
  head_local="$(git rev-parse HEAD)"
  if [[ "$head_remote" == "$head_local" ]]; then
    pass "repo clone: on-host clone is at ${head_local:0:8}"
  else
    commit_age=$(( (now - $(git show -s --format=%ct HEAD)) / 60 ))
    if (( commit_age < 60 )); then
      say "NOTE  repo clone: on-host clone at ${head_remote:0:8}, this commit is ${commit_age}m old — the */15 puller has not caught up"
    else
      fail "repo clone: on-host clone is at ${head_remote:0:8}, HEAD is ${head_local:0:8} (${commit_age}m old) — the auto-pull cron is likely broken"
    fi
  fi
fi

# --- 6. Docker boot-guard drop-in ---------------------------------------------------
if ! live="$(probe boot-guard)"; then
  fail "boot guard: boot-guard verb failed (drop-in missing?)"
elif [[ "$live" == *'$'* ]]; then
  fail "boot guard: the live drop-in contains a bare \$ — systemd expands it in unit files"
elif ! want="$(sh scripts/docker-boot-guard.sh --print-dropin)"; then
  fail "boot guard: could not render the drop-in from scripts/docker-boot-guard.sh"
elif [[ "$live" != "$want" ]]; then
  fail "boot guard: the live drop-in differs from what scripts/docker-boot-guard.sh generates — re-run it on the NAS (it only regenerates at boot)"
else
  pass "boot guard: the live drop-in matches the generator"
fi

# --- 7. Certificate expiry ----------------------------------------------------------
# Public names from the SNI map; the A1 terminates its own TLS, so those are probed there.
before=$fails
nas_hosts="$(grep -oE '"[01]:[a-z0-9.-]+\.[a-z]+"' stacks/micro-vps-ingress/docker-compose.yml \
  | tr -d '"' | cut -d: -f2 | sort -u)"
a1_ip="$(sed -n '/^## Cloud hosts/,/^## Docker networks/p' docs/network.md \
  | grep -oE 'Ampere A1[^|]*\| `[0-9.]+`' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
a1_hosts="$(grep -oE '^      [a-z0-9.-]+\.example\.com \{' stacks/a1-vps-matrix/docker-compose.yml \
  | awk '{print $1}' | sort -u)"
checked=0
check_cert() {
  local host="$1" addr="$2" dates notafter notbefore left life
  if ! dates="$(echo | timeout 15 openssl s_client -connect "$addr:443" -servername "$host" 2>/dev/null \
      | openssl x509 -noout -dates 2>/dev/null)" || [[ -z "$dates" ]]; then
    fail "cert: $host served no certificate from $addr"
    return
  fi
  notbefore="$(date -d "$(sed -n 's/^notBefore=//p' <<<"$dates")" +%s)"
  notafter="$(date -d "$(sed -n 's/^notAfter=//p' <<<"$dates")" +%s)"
  left=$(( (notafter - now) / 3600 ))
  life=$(( (notafter - notbefore) / 86400 ))
  checked=$((checked + 1))
  # Short-lived certs are normal now, so the threshold is relative to the cert's own life.
  if (( life <= 10 )); then
    (( left >= 24 )) || fail "cert: $host expires in ${left}h (${life}d cert)"
    (( left >= 48 )) || warn "cert: $host expires in ${left}h (${life}d cert)"
  else
    (( left >= 168 )) || fail "cert: $host expires in $((left / 24))d (${life}d cert)"
    (( left >= 336 )) || warn "cert: $host expires in $((left / 24))d (${life}d cert)"
  fi
}
# Caddy's plain :443, never :8443, which expects a PROXY-protocol header.
for h in $nas_hosts; do check_cert "$h" "$nas"; done
if [[ -n "$a1_ip" ]]; then
  for h in $a1_hosts; do check_cert "$h" "$a1_ip"; done
else
  warn "cert: no A1 address in docs/network.md, its names unchecked"
fi
if [[ $fails -eq $before ]]; then pass "certs: $checked name(s) valid well past their renewal window"; fi

# --- 8. Hetzner Storage Box snapshots -----------------------------------------------
before=$fails
if ! box="$(probe storagebox 2>&1)"; then
  fail "storage box: storagebox verb failed ($(tr '\n' ' ' <<<"$box" | head -c 160))"
elif [[ "$box" == "NO TOKEN"* ]]; then
  skip "storage box: no read-only Hetzner token on the NAS yet (${box#NO TOKEN })"
elif [[ "$box" == ERROR* ]]; then
  fail "storage box: $box"
else
  count=0
  newest_snap=0
  while read -r kind created _rest; do
    [[ "$kind" == SNAPSHOT ]] || continue
    ts="$(date -d "$created" +%s 2>/dev/null)" || continue
    count=$((count + 1))
    (( ts > newest_snap )) && newest_snap=$ts
  done <<<"$box"
  if (( count == 0 )); then
    fail "storage box: the API returned no snapshots at all"
  else
    age="$(hours_since "$newest_snap")"
    (( age <= STORAGEBOX_MAX_H )) || fail "storage box: newest snapshot is ${age}h old (threshold ${STORAGEBOX_MAX_H}h) — the daily schedule stopped"
    (( count >= STORAGEBOX_MIN_COUNT )) || fail "storage box: only $count snapshots kept, expected at least $STORAGEBOX_MIN_COUNT"
    if [[ $fails -eq $before ]]; then
      pass "storage box: $count snapshots, newest ${age}h old"
    fi
  fi
fi

say "RESULT  $fails failure(s)"
exit $((fails > 0 ? 1 : 0))
