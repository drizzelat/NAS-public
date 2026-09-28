# NAS nightly health check — agent instructions

Headless in a GitHub Actions job on the self-hosted runner (a container in the runner VM, on the
NAS LAN). Verify the important parts of the NAS are healthy, report. The repo is checked
out in the working directory and is the **source of truth**: derive every expected
value — hosts, pools, datasets, dump locations, schedules, endpoints — from `docs/`,
`scripts/`, `stacks/` at run time, never from memory or from examples in this file.
New services/datasets/dump targets added to the repo get picked up automatically.

## Style

Terse register. Drop articles, filler, hedging. Fragments fine.

- No preamble, no narration of what you are about to do, no restating the checklist
  back, no "Now compiling the final report."
- Evidence cell is **one line**: the decisive number or line. Never a command dump,
  never a raw log paste — quote the shortest decisive fragment.
- A passing check is one row and nothing more. Expand only what FAILed.
- Exact strings stay verbatim: error text, digests, commands, thresholds, `klass`
  values. Compress prose, never identifiers.
- `## Action needed` is the one place clarity beats brevity — each item names the
  thing, the fault, and the exact command or file to fix it.

## Access

**SSH to the NAS host gives a fixed verb list, not a shell.** The key in
`$NAS_SSH_KEY_FILE` belongs to `nashealth`, an unprivileged TrueNAS user whose
`authorized_keys` pins a forced command (`scripts/nas-health-probe.sh`, installed on
the host). Anything not in the table below exits **111** with
`nas-health-probe: refused (...)` and runs nothing. No shell, no `sudo`, no `scp`, no
port forwarding, no PTY — do not work around this, and do not report a refusal as a
NAS fault. Setup: `docs/runbooks/setup-operations/nas-health-check.md`.

```sh
ssh -i "$NAS_SSH_KEY_FILE" -o StrictHostKeyChecking=accept-new \
  nashealth@<lan-ip> '<verb> [args]'   # LAN IP from docs/network.md
```

The user is `nashealth`, not the `truenas_admin` in that file's SSH access table —
that account is for humans and this key does not open it.

| Verb | Gives you | Used by |
| --- | --- | --- |
| `help` | the verb list the host actually has | — |
| `host` | failed systemd units, `NTPSynchronized`, boot time | 3 |
| `alerts` | `alert.list` | 2 |
| `pools` | `zpool status` + `zpool list -o name,capacity,health` | 4 |
| `datasets` | `zfs list -o name,mountpoint` | 6 |
| `smart` | `smartctl -H -A` **and** `-l selftest` for every scanned device | 5 |
| `disks` | `disk.query` | 5 |
| `cloudsync` | last 200 lines of the chain log + `cloudsync.query` task state | 7 |
| `paths PATH...` | `OK`/`MISSING` per path | 6 |
| `yaml2json` | YAML on **stdin** → JSON on stdout (the runner has no PyYAML) | 8 |
| `version` | `sha256` of the installed scripts | — |

`snapshots`, `dumps`, `repo-head`, `boot-guard` and `storagebox` exist too, and belong to the
deterministic probe below — do not call them here.

`PATH` arguments must be absolute under `/mnt` with no `..` and no characters
outside `A-Za-z0-9._/-`; anything else is refused. `paths` takes as many
arguments as you like — pass the whole list in one call.

- **Komodo API** (the `probe-read` service user):

  ```bash
  kr() { curl -sS --resolve "$KOMODO_RESOLVE" -X POST -H 'Content-Type: application/json' \
    -H "X-Api-Key: $KOMODO_API_KEY" -H "X-Api-Secret: $KOMODO_API_SECRET" -d "$2" "$KOMODO_URL/read/$1"; }
  kr ListServers '{"limit":0}' | jq -r '.[] | [.id, .name, .info.state] | @tsv'
  ```

  - Discover the Servers with `ListServers`; do not assume a fixed list.
  - Define `kr` in the same command that uses it: a shell function does not survive between
    tool calls.
  - **Every list call takes `"limit":0`.** Without it Komodo returns a page of 50 and says
    nothing.
- **Never let `InspectContainer` output reach the context.** It carries every
  container's environment, secrets included. Pipe it straight into `jq` in the same
  command and select only the field you need (check 12).
- No Docker access over SSH — read container state through the Komodo API.
- The runner is on the LAN with outbound internet, so it can probe endpoints directly
  (`openssl s_client`, `curl`). A tool the check needs missing from the runner image →
  **SKIP** that check with the reason.
- A verb this checklist names but missing from `help` means the host copy of the probe
  is older than this file: **SKIP** the checks that need it, name the verb, say the
  probe needs re-installing.

## Cost

Every turn re-reads the whole context, so volume compounds — a big tool result is paid
for again on every turn after it. Late turns cost the most: by the last checks each turn
re-reads well over 100k tokens, so a result pulled in at the start is paid for dozens of
times.

- One verb = one `ssh`, and `paths` takes a whole list at once.
- Never re-fetch data already in context.
- Checks 5 and 8 come with helpers in `.github/scripts/` that print only what the check
  judges. Run them as the check says, and never gather that data by hand as well.
- Filter at the source. Pipe through `jq`/`grep`/`head` in the same command rather than
  pulling a whole API listing or log into context to read three fields out of it.
- **Never read a repo doc whole** — no `cat`, no `sed -n '1,200p'`, no `Read` of
  `docs/scheduled-tasks.md`, `docs/network.md` or `docs/storage.md`. Pull the section:
  - cadences: `grep -n '^###' docs/scheduled-tasks.md` — most headings carry theirs;
    Cloud Sync needs the body, e.g.
    `sed -n '/^### Cloud Sync/,/^### /p' docs/scheduled-tasks.md`
  - NAS LAN IP: `sed -n '/^## NAS host/,/^## /p' docs/network.md`; A1/VPS addresses:
    `sed -n '/^## Cloud hosts/,/^## /p' docs/network.md`
  - mount-table paths: `sed -n '/^## Shares/,/^## /p' docs/storage.md | grep -oE '/mnt/[A-Za-z0-9._/-]+' | sort -u`;
    known orphans: `grep -n -i -A2 'orphan' docs/storage.md`
- Any other long file (runbooks, service docs, scripts): `grep` it, never read it whole.
  A result too large for one tool call is saved to a file — `grep` that file too.

## Hard rules

- **Read-only.** The verb list is read-only by construction on the NAS side, so the
  rule that still needs your care is the Komodo API: `/read/` paths only, never
  `/write/` or `/execute/`. `probe-read` cannot deploy, but a refused execute still
  writes a failed update record.
- A refusal from the probe (exit **111**) is **your** mistake, not a NAS fault. Re-read
  the verb table, or run `help`. Never report it as a finding.
- A check that errors for an unexpected reason (timeout, parse failure) is **FAIL**
  with the error, not SKIP.

## Checks

**Seven checks are not here any more.** Snapshot recency and retention, scrub age, dump
freshness and integrity, cert expiry, the on-host repo clone and the boot-guard drop-in are
yes/no, so they moved to
[`.github/scripts/nas-deterministic-checks.sh`](scripts/nas-deterministic-checks.sh), which the
[deploy-state probe](../docs/runbooks/setup-operations/deploy-state-probe.md) runs four times a
day — sooner than nightly and at no token cost. Do not re-do them here: a finding of theirs turns
that probe's run red on its own. What is left is what needs judgement.

Freshness rule for every recency check: read the documented cadence from the repo
source the check names, then allow slack — **cadence + 2 h** for hourly/daily jobs,
**+5 days** for scrubs. State the repo source and the derived threshold in the evidence.

### Host

1. **SSH reachability** — the `host` verb returns. If not: FAIL this check, SKIP
   everything needing SSH, still finish the report.
2. **TrueNAS alerts** — the `alerts` verb. FAIL on any active (`dismissed: false`)
   alert of level `CRITICAL`/`ERROR`; note `WARNING` inline as a warning. Quote the
   `klass` and its formatted text. TrueNAS's own alert surface; catches
   problems the checks below do not model — never skip it because others passed.
3. **Host basics** — the `host` verb. `systemctl --failed` must be empty (name any
   failed unit, FAIL). `NTPSynchronized` must be `yes`, FAIL on `no`.
   Warn if the host booted in the last 24 h.

### Storage

4. **ZFS pools** — the `pools` verb (`zpool status` + `zpool list`). **Every** pool the
   host reports must be `ONLINE`
   with zero read/write/checksum errors. Capacity: FAIL >90%, warn >80% (still PASS).
5. **SMART** — a pool reads `ONLINE` while a member disk dies. The `smart` verb reports
   **every** device `smartctl --scan` finds — health, attributes, self-test log — in one
   call; pass it no device. The raw output is ~16 KB, so never spool it to a file or read
   it back: pipe it through the filter, which keeps per device the health line, the
   attributes below plus `Power_On_Hours`, and the newest self-test entries, and passes
   through any line it does not recognise —
   `ssh … 'smart' | awk -f .github/scripts/nas-health-smart-summary.awk`.
   `disks` maps devices to models/serials; filter it too:
   `ssh … 'disks' | jq -r '.[] | [.name, .model, .serial] | @tsv'`. FAIL when overall health is not `PASSED`. Warn on non-zero
   `Reallocated_Sector_Ct`, `Current_Pending_Sector` or `Offline_Uncorrectable` (SATA),
   or `media_errors` > 0 / `percentage_used` > 80 (NVMe). From the self-test log: FAIL
   if the newest completed self-test did not pass, warn if it is older than the SMART
   cadence in `docs/scheduled-tasks.md` plus slack. `apps` is single-disk, no redundancy.
6. **Storage drift** — two directions, repo against host:
   - **Missing bind-mount paths (FAIL).** Collect every host path (`/mnt/...`) on the
     left of a `volumes:` entry across `stacks/*/docker-compose.yml`, pass the whole
     list to `paths` in one call. Not harmless: Docker creates a root-owned empty dir and
     the app comes up with empty state *looking* healthy. Only stacks running **on the
     NAS** — one whose Komodo Stack is on another Server (check 8) is on a VPS and
     its paths do not exist here.
   - **Orphan datasets (warning, never FAIL).** The `datasets` verb against those paths
     plus the mount table in `docs/storage.md`. Report datasets backing no stack and
     appearing in neither. Excluded by design, do not report: TrueNAS-managed
     (`apps/.system`, `apps/.ix-virt`, `apps/ix-apps`, `boot-pool/*`), the on-host repo
     clone dataset (path in `docs/runbooks/setup-operations/nas-repo-autopull.md`), the
     SMB share datasets under `data/smb_share`, and anything `docs/storage.md` already
     documents as a known orphan awaiting deletion. Also warn on the reverse drift: a
     path in the `docs/storage.md` mount table that does not exist on the host.

### Backups

7. **Cloud sync chain** — only offsite protection for the non-redundant `apps` pool, and
    nothing else alerts on it going stale. The `cloudsync` verb returns the log tail (path is `LOG=` in `scripts/cloudsync-chain.sh`).
    The last `chain done (fail=N)` line must be younger than the chain's cadence
    (`docs/scheduled-tasks.md`) plus slack, with `N` = 0. FAIL on a non-zero `fail=`, a
    stale last run, or a `chain start` with no matching `chain done` (hung or killed
    run). Name the failed datasets from the `FAIL <dataset>` lines. Cross-check the
    template task's last job state against the `cloudsync.query` section of the same
    output — it carries `state` and `time_finished` per task. Log unreadable → SKIP with
    that reason.

### Repo vs live

8. **Deployed stacks match the repo** — `kr ListStacks '{"limit":0}'`, reading `.name`,
    `.info.server_id` (the Server name comes from `ListServers`) and `.info.state` per Stack.
    A Stack's name is its folder name under `stacks/`.
    - Komodo Stack with no matching repo folder → FAIL (untracked, cannot be redeployed
      from the repo).
    - Repo folder with no Komodo Stack → FAIL, **unless** its `docs/services/<name>.md`
      documents it as applied by hand — a TrueNAS custom app or a Komodo
      periphery. Then note it.
    - A Stack whose `.info.state` is not `running` → FAIL. Except `github-runner` in `deploying`:
      its `pre_deploy` is waiting for this very job to end. Note it, no FAIL.
    - **Image digest drift — one command; never list containers or pins by hand:**
      `.github/scripts/nas-health-image-drift.sh <nas-lan-ip>` (~90 s). Per running
      container on every Komodo Server it maps the compose project/service labels to the
      `tag@sha256:` pin in `stacks/<stack>/docker-compose.yml` (a TrueNAS app's project
      `ix-<app>` → `stacks/<app>`, a periphery's project `periphery` → `stacks/<server>-periphery`) and resolves the digest actually running properly:
      Komodo `read/InspectImage` on the container's image, pin matched against
      `RepoDigests` — never the container's `ImageID`, which is the image *config* digest
      and never equals the manifest digest in the pin. Containers whose compose entry is
      not digest-pinned are skipped. It prints findings only, then a `SUMMARY` line:
      - `DRIFT` → FAIL, naming stack, image, pinned and running digest: a merge never
        redeployed, or someone changed a container outside Komodo. **Always report how long
        each drift has existed** — the line carries `drifting since <YYYY-MM-DD> (<N>d)`
        from `git log -1 --format=%ad --date=short -S'<pinned-digest>' -- stacks/<stack>/docker-compose.yml`,
        the day the pin that is *not* running was merged. Without the age a stack stuck two
        weeks reads exactly like a pin merged four hours ago.
      - A drift older than ~1 day means the redeploy path failed, not a merge yet to
        deploy. Say so in *Action needed*, point at a dispatched deploy of that stack
        (`gh workflow run deploy-stacks.yml -f stacks=<stack>`); still drifting the next night is a second
        bug, not a slow deploy.
      - `NO SERVICE` (a running container whose service is gone from the repo compose) →
        FAIL, same cause as a drift.
      - `NO REPO COMPOSE` → FAIL: a compose project no folder explains.
      - `ERROR` → FAIL with the error, naming what went unchecked.

9. **Cloudflare range drift** — two files pin Cloudflare's published IP ranges, and
    they are load-bearing in different ways: `stacks/caddy/Caddyfile`
    (`trusted_proxies static …`) decides whose `CF-Connecting-IP` is believed, and the
    `geo $cf_edge` block in `stacks/micro-vps-ingress/docker-compose.yml` decides who may
    reach the four orange-clouded names at all. **The nginx one fails closed** — a range
    Cloudflare added and this file lacks is an outage for `auth`/`files`/`immich`/`mealie`,
    not a degraded signal. Compare both against upstream as sets:

    ```bash
    for u in ips-v4 ips-v6; do curl -fsS --retry 3 --retry-all-errors \
      "https://www.cloudflare.com/$u"; echo; done | grep . | sort -u > /tmp/cf.want
    grep -o 'trusted_proxies static .*' stacks/caddy/Caddyfile \
      | cut -d' ' -f3- | tr ' ' '\n' | grep . | sort -u > /tmp/cf.caddy
    sed -n '/geo \$\$cf_edge/,/^ *}/p' stacks/micro-vps-ingress/docker-compose.yml \
      | grep -oE '[0-9a-fA-F:.]+/[0-9]+' | sort -u > /tmp/cf.nginx
    diff /tmp/cf.want /tmp/cf.caddy; diff /tmp/cf.want /tmp/cf.nginx
    ```

    Either diff non-empty → FAIL, naming the file and the added/removed ranges (`<` is
    upstream-only, i.e. the dangerous direction for the nginx list). *Action needed* is
    the edit plus a redeploy of that stack. Both lists carry v6 although the VPS servers
    are v4-only, so a v6-only difference is still a real finding, not noise.

### Edge

10. **Suspicious external traffic, last 24 h** — the Caddy access log is the only record
    of what reached the edge. Needs `GRAFANA_TOKEN` (Viewer service account); unset →
    **SKIP**. Query VictoriaLogs through Grafana's datasource proxy — the stores publish
    no host port.

    **`--resolve` to the NAS LAN IP.** `grafana.example.com`
    is LAN-only in Caddy but still resolves *publicly* to Cloudflare, so a runner whose
    DNS is not AdGuard would be sent to Cloudflare, then to the VPS, which drops it — the
    name is not in the SNI allowlist. The connection would hang and the check would FAIL
    for a reason that has nothing to do with the edge. Host and LAN IP come from
    `docs/network.md`, like every other value here:

    ```bash
    q() { curl -fsS --resolve "grafana.example.com:443:<nas-lan-ip>" \
      -H "Authorization: Bearer $GRAFANA_TOKEN" -G \
      "https://grafana.example.com/api/datasources/proxy/uid/victorialogs/select/logsql/query" \
      --data-urlencode "query=$1" --data-urlencode "limit=${2:-20}"; }
    ```

    The certificate validates without `-k`: it is Caddy's own wildcard, and `--resolve`
    changes where the connection goes, not the name being verified.

    `geo_country` is assigned by Vector, not MaxMind: `local` is LAN/tailnet/loopback and
    `monitor` is Uptime Kuma. Excluding both leaves genuine outside traffic, which is
    normally a dozen requests a day — see `docs/services/observability.md`.

    Three questions, one call each. Report the counts in the evidence even when all are
    zero; that line is the whole point of the check.

    - **Scanner paths**, with the top offenders by `client_ip`:

      ```
      service:caddy AND _time:24h AND geo_country:!local AND geo_country:!monitor
        AND host:!"grafana.example.com"
        AND uri:re("(?i)(\\.env|wp-|phpmyadmin|\\.git/|xmlrpc|/passwd|\\.aws|actuator|struts)")
        | stats by (client_ip, host, uri, status) count() as hits | sort by (hits desc)
      ```

      Any hit with a status other than `403` is a FAIL: the probe got past the edge. Hits
      that are *all* `403` are a `warn:` with the count and top client, not a FAIL — the
      edge (a CrowdSec ban, AppSec or a Caddy block) refused every one, and check 11 says
      which. A standing-ban IP still knocking is exactly this case.

      The `grafana` exclusion is not cosmetic: this checklist's own LogsQL goes through
      Caddy as a query string, so an unfiltered pattern matches itself.
    - **Auth failures from outside.** `status:=401 OR status:=403`, same exclusions,
      grouped by `client_ip` and `host`. ≥ 20 in 24 h → FAIL (credential stuffing shape);
      1–19 → `warn:` with the count and the top client.
    - **Real-IP canary**, on a **15 m** window, not 24 h: this is a config state, not an
      event — if `trusted_proxies` has stopped matching, it is broken right now, and a
      24 h window would just re-report the backlog from before the change landed.

      Kuma is the reference signal. It probes the public names through Cloudflare from the
      A1 roughly every minute, so its `monitor` rows must carry the A1's address (in
      `docs/network.md`; do not hardcode it) and never a Cloudflare edge one:

      ```
      service:caddy AND _time:15m AND geo_country:monitor AND client_ip:!"<a1-ip>"
        | stats by (client_ip) count() as hits
      ```

      Non-empty → FAIL: either `trusted_proxies` stopped matching and every geo, ban and
      rate limit is aimed at a Cloudflare PoP again, or the A1's address changed and
      `docs/network.md` is stale. Both are worth a human. See `docs/services/caddy.md` →
      Real client IP behind Cloudflare. Expect ~100 monitor rows in 15 m; near-zero means
      Kuma itself is down, which is check 12's job, not this one.

      > Do **not** write this as `asn_org:"Cloudflare"` over all traffic. Two reasons: the
      > `monitor` rows carry no `asn_org` at all (Vector skips enrichment for them), and a
      > visitor on Cloudflare WARP legitimately egresses from a Cloudflare address, so that
      > form has a real false-positive source. Kuma's known-good client IP has neither
      > problem.

11. **CrowdSec remediation, last 24 h** — the companion to check 10: that check says what
    reached the edge, this one says what CrowdSec did about it. **Over the same 24 h
    window**, because a local ban defaults to 4 h and the nightly run is ~11 h behind the
    traffic it is reading — an instant decisions query says nothing about whether the
    remediation fired, only whether it is still in force. Same Grafana proxy,
    VictoriaMetrics datasource, so the same SKIP rule applies:

    ```bash
    m() { curl -fsS --resolve "grafana.example.com:443:<nas-lan-ip>" \
      -H "Authorization: Bearer $GRAFANA_TOKEN" -G \
      "https://grafana.example.com/api/datasources/proxy/uid/victoriametrics/api/v1/query" \
      --data-urlencode "query=$1"; }
    ```

    Three questions, one call each; report all three counts even when zero.

    - **Log scenarios that fired**, by `name`:

      ```
      ((cs_bucket_overflowed_total - cs_bucket_overflowed_total offset 24h)
        or cs_bucket_overflowed_total) > 0
      ```

    - **AppSec inband rules that blocked**, by `rule_name`, plus the request total from
      `cs_appsec_block_total` in the same shape. That total is the same event check 10
      counts as `403`s, from the other side: quote both, and say so when they agree.

      ```
      ((cs_appsec_rule_hits - cs_appsec_rule_hits offset 24h) or cs_appsec_rule_hits) > 0
      ```

      > Do **not** write either of these as `increase(...[24h])`. CrowdSec registers a
      > scenario's series on its *first* event, so a rule that fired for the first time
      > inside the window has no earlier sample to subtract from, and `increase()` reads
      > it as `0` — exactly the rules you most want to see. The `offset`/`or` form takes
      > the delta where there is history and the whole counter where there is not. A
      > `crowdsec` restart resets these counters, so a negative delta is a restart, not a
      > quiet night; check 12 covers the restart itself.
    - **Decisions in force right now**: `cs_active_decisions{origin!="CAPI"}`, unchanged.
      `origin="cscli"` rows are the standing manual bans in
      `docs/runbooks/setup-operations/crowdsec-bouncer.md` → Standing manual bans; match
      them against that table and report only as a one-line note. A row that is *not* in
      the table is a `warn:` with its `origin` and `reason`.

    None of the three is a FAIL on its own — the remediation layer working is good news,
    and check 10 already FAILs on any of the traffic that got past it. Any non-zero count is a `warn:` with the
    scenario names and counts, and goes in *Action needed* only when check 10 shows the
    source was still served (a `200`) after the scenario fired. All three empty is a
    one-line PASS. If `cs_active_decisions` is absent entirely, even unfiltered, the
    CrowdSec scrape target is down — that is a FAIL, and check 12 should already show it.

### Services

12. **Containers** — per Komodo Server, `kr ListDockerContainers '{"server":"<name>"}'`, every
    state, filtered at the source to `.name`, `.state` and `.status`. FAIL for any container
    restarting, exited non-zero, or running-but-`unhealthy`. `Exited (0)` (run-once/init) is
    fine. Running-but-unhealthy whose last healthcheck log shows the probe binary missing from
    the image is a known false alarm — note it, do not FAIL. Read that log with
    `kr InspectContainer '{"server":"<name>","container":"<c>"}' | jq -r '.State.Health.Log[-1].Output'`,
    in one command, never unfiltered.
## Report

Markdown to stdout: one table row per check —
`| # | check | PASS/FAIL/SKIP | evidence |` — grouped under the same
`## Host / ## Storage / ## Backups / ## Repo vs live / ## Edge / ## Services` headings as
above.
Warnings go in the evidence cell prefixed `warn:`. Findings a human should act on go in
a final `## Action needed` section (omit when clean).

The **very last line** of your output must be exactly `HEALTH: OK` or `HEALTH: FAIL` —
bare text on its own line, no code fence, no backticks, no trailing punctuation, nothing
after it.

`OK` only when no check FAILed (SKIPs and warnings are OK). The workflow greps this
line; a FAIL turns the run red and GitHub emails the failure — that is the alert path,
so do not soften a genuine failure.
