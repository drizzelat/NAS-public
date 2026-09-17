# Service: Observability (Vector + VictoriaLogs + VictoriaMetrics + Grafana)

## Overview

One place to ask what traffic is actually hitting the NAS, and the pipeline to answer the same
kind of question about any other service later. It replaces the GoAccess report that lived inside
the NPMplus image and went with it at the [Caddy cutover](caddy.md) — `goaccess.example.com` was
a `503` placeholder from 2026-09-07 until this stack retired the name.

GoAccess rendered a fixed report. This is a query engine with a UI on top: filter to one client
IP, one vhost, one status class, one country, over any window, and every panel follows.

**It is deliberately two stores, not one.** Most services expose Prometheus metrics rather than
logs, so a logs-only stack would have dead-ended at the first non-Caddy service. Splitting them
now costs one container and means adding a service later is one config file, never a re-architecture.

## Stack

| Container | Role |
| --------- | ---- |
| `vector` | tails log files, parses and enriches, fans out to both stores |
| `victorialogs` | log store — full-text + structured, queried with LogsQL |
| `victoriametrics` | metrics store **and** the Prometheus scraper (`-promscrape.config`, so no separate vmagent) |
| `grafana` | the single visual layer over both |
| `geoipupdate` | refreshes the MaxMind mmdb files Vector reads |

- **Stack folder:** `stacks/observability/`
- **Compose file:** `stacks/observability/docker-compose.yml`
- **Deploy:** Komodo Stack `observability` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value |
| ----- | ----- |
| URL | `https://grafana.example.com` — **LAN-only** |
| Auth | Grafana local admin. Sign-up disabled; no Authentik integration yet (see [Notes](#notes)) |
| Host ports | **none.** Everything is reached through Caddy over `proxy_observability` |

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/etc/vector` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/observability/vector` | Vector pipeline, from Komodo's clone on the NAS. The **directory** — see the note below |
| `/var/log/caddy` (`ro`) | `/mnt/apps/caddy/logs` | Caddy's access log, the one source today |
| `/geoip` (`ro`) | `/mnt/apps/observability/geoip` | mmdb files, written by `geoipupdate` |
| `/var/lib/vector` | `/mnt/apps/observability/vector` | Read checkpoints, so a restart does not re-ingest |
| `/victoria-logs-data` | `/mnt/apps/observability/victorialogs` | Log store |
| `/etc/victoriametrics` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/observability/victoriametrics` | Scrape config, from the clone |
| `/victoria-metrics-data` | `/mnt/apps/observability/victoriametrics` | Metrics store |
| `/etc/grafana/provisioning` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/observability/grafana/provisioning` | Datasources + dashboard provider, from the clone |
| `/etc/grafana/dashboards` (`ro`) | `/mnt/apps/komodo/repos/nas/stacks/observability/grafana/dashboards` | Dashboard JSON, from the clone |
| `/usr/share/GeoIP` | `/mnt/apps/observability/geoip` | Same directory, the writer's side |

> **A merged config change is live once `deploy-stacks` has deployed this stack, with no container
> restart.** The Vector pipeline, the scrape config and the dashboards are bind-mounted out of
> Komodo's clone at `/mnt/apps/komodo/repos/nas`, and a change to any of them is a change to this
> stack's folder, so the deploy pulls it. Each consumer then re-reads on its own:
>
> - Vector runs `--watch-config`.
> - VictoriaMetrics re-reads `scrape.yml` every minute.
> - Grafana's dashboard provider polls every 60 s.
>
> The Stack's `post_deploy` fails the deploy unless every mount shows the clone's files
> ([`scripts/komodo/mount-matches.sh`](../../scripts/komodo/mount-matches.sh), komodo-migration.md
> F28). Until 2026-09-17 these came from the 15-minute pull of `/mnt/apps/scripts/nas`; [Caddy](caddy.md)
> and the [Authentik blueprints](authentik.md#configuration-in-git-blueprints) moved the same day.
>
> **The mounts are directories, not files.** Load-bearing, and the same trap the Caddyfile hit:
> `git` replaces a file's inode on pull, and a single-file bind mount stays bound to the old one
> forever. See [caddy.md](caddy.md) → Volumes.

## Environment variables

Set as Komodo Variables `OBSERVABILITY__<KEY>` (`scripts/secrets.sh push observability`); the plaintext lives in the gitignored
`secrets/portainer-env/observability.env` and the ciphertext in `secrets.enc/` — see the
[secret-sync runbook](../runbooks/setup-operations/secret-sync.md).

| Variable | Description |
| -------- | ----------- |
| `GRAFANA_ADMIN_PASSWORD` | Initial Grafana `admin` password. Changing it later in the UI wins; this only seeds |
| `MAXMIND_ACCOUNT_ID` | MaxMind account id for GeoLite2 (free account) |
| `MAXMIND_LICENSE_KEY` | MaxMind licence key for the same account |

## How it works

```
/mnt/apps/caddy/logs/access.log
        │
     vector  ── parse JSON, GeoIP + ASN lookup, derive counters
        ├──► victorialogs   (raw enriched events, 90d)
        └──► victoriametrics (caddy_requests_total, caddy_response_bytes_total, 1y)
                  ▲
                  └── also scrapes: crowdsec:6060, server:9300 (authentik),
                                    itself + victorialogs, and by IP:
                                    192.168.178.111:9999 (snowflake),
                                    192.168.178.111:9998 (conduit),
                                    100.64.0.13:9035 (tor bridge, A1),
                                    100.64.0.13:9036 (webtunnel bridge, A1),
                                    100.64.0.13:9037 (chrony exporter, A1),
                                    gluetun:9022 (qbittorrent exporter),
                                    gluetun:9023 (sabnzbd exporter),
                                    exportarr-{sonarr,radarr,prowlarr,bazarr}:9707
                                    and jellyfin-exporter:9594
                            │
                         grafana  ── both datasources, dashboards from git
```

### Two naming conventions carry the whole extension story

`stacks/observability/vector/00-global.yaml` defines the sinks once and selects their inputs by
**glob**, so a new service never edits it:

| Name a component | And it goes to |
| ---------------- | -------------- |
| `out_<service>` | VictoriaLogs |
| `metrics_<service>` | VictoriaMetrics |

`10-caddy.yaml` is the worked example. Vector merges every file in the directory, so adding a
service is one new `10-<service>.yaml` and nothing else.

### Adding a service

**Logs** — write `stacks/observability/vector/10-<service>.yaml` with a source, and a transform
named `out_<service>`. Set `.service` on the event; keep `_stream_fields` low-cardinality (see
[Notes](#notes)). Merge, wait for the pull.

**Metrics** — add a `scrape_config` to `stacks/observability/victoriametrics/scrape.yml`, and add
that stack's `proxy_<stack>` network to the `victoriametrics` service in
`stacks/observability/docker-compose.yml`. Both edits are required: the scraper can only reach a
target on a network it has joined.

**No `proxy_` network to join?** A `network_mode: host` container or an off-NAS host is scraped by
IP instead: `snowflake` and `conduit` on the NAS LAN IP, the A1's `tor-bridge` and `tor-webtunnel`
over the tailnet. Bind the exporter to that one address, never to `0.0.0.0` on a public host.

> **Not a shared `metrics_net`.** Joining the networks one at a time is more edits, but a single
> flat metrics network re-creates the cross-stack exception `media_net` already is — see
> [network.md](../network.md) → Adding a New Stack.

### Dashboards

All in the **NAS (git)** folder. The three Caddy-derived ones need no per-app exporter — every
vhost behind the proxy appears in them automatically.

| Dashboard | uid | Source | What it answers |
| --------- | --- | ------ | --------------- |
| Apps — Overview | `apps-overview` | Caddy log | Which apps are being used, by whom, from where, and which are erroring or idle |
| App — Detail | `app-detail` | Caddy log | One app (`$app` selector): paths, latency, clients, user agents, errors, raw requests |
| Caddy — Traffic | `caddy-traffic` | Caddy log | The edge itself: throughput, status mix, egress, countries |
| CrowdSec — Security | `crowdsec-security` | `crowdsec:6060` | Bans in force, scenarios firing, parser health, bouncer polling |
| Authentik — Identity | `authentik-identity` | `server:9300` | SSO request rate, latency, outpost connectivity, task backlog, DB load |
| Tor — Bridges & Snowflake | `tor-traffic` | `100.64.0.13:9035` + `:9036` + `192.168.178.111:9999` | Traffic through the A1 [obfs4](a1-vps-tor-bridge.md) and [WebTunnel](a1-vps-webtunnel.md) bridges and the [NAS Snowflake proxy](snowflake.md); bridge egress month-to-date and projected against the 2 TiB their two caps add up to. UTC, to match Tor accounting and Oracle billing |
| Community services | `community-services` | the Tor, Snowflake and Conduit targets above + `100.64.0.13:9037` (`ntp`) + `gluetun:9022` (`qbittorrent`) | Everything run for other people on one page: status, users/clients, traffic per service, then a section each for the [bridges](a1-vps-tor-bridge.md), [Snowflake](snowflake.md), [Conduit](conduit.md), the [NTP Pool server](a1-vps-ntp.md) (queries, drops, offset, upstreams) and [Kiwix seeding](../runbooks/setup-operations/kiwix-seeding.md) (upload, peers, incoming port, per-file table). Bridge accounting detail stays in `tor-traffic` |
| Media stack | `media-stack` | `jellyfin-exporter:9594` (`jellyfin`) + `exportarr-*:9707` (`sonarr`, `radarr`, `prowlarr`, `bazarr`) + `gluetun:9023` (`sabnzbd`) + `gluetun:9022` (`qbittorrent`) + Caddy log | [Jellyfin](jellyfin.md), the [\*arr apps](arr.md) and the [download clients](downloads.md): status and headline numbers, then a section each for Jellyfin (now playing, sessions, watch time per user, play method, transcode reasons and detail, egress, library counts), the library (series/movies on disk, missing, below cutoff, size, quality), downloads (queues, throughput, torrent states, incomplete torrents, SABnzbd queue, Usenet provider usage), Prowlarr indexers (queries, grabs, failures, response time), Bazarr subtitles, and health (each app's health checks, free space, web UI requests and 5xx, exporter scrape time) |
| Observability — Pipeline Health | `observability-health` | self-scrape | Is the telemetry itself working — the one that catches silent drops |

> **Why most apps have no dashboard of their own.** Paperless, RomM, Mealie, Immich and the rest
> expose no Prometheus endpoint without adding a third-party exporter container each. Rather than
> run a dozen sidecars, they are covered by *App — Detail*, which derives per-app traffic, latency
> and client breakdowns from the Caddy access log. The media stack is the exception: what matters
> there (what is playing, what is missing, what is stuck) is app state no access log contains, so
> Jellyfin and each \*arr app got an exporter for *Media stack*. Immich and
> Uptime Kuma can expose real metrics with a config change (`IMMICH_TELEMETRY_INCLUDE`, and an API
> key for Kuma's `/metrics`); neither is enabled.

### Dashboards are code

`stacks/observability/grafana/dashboards/*.json` is provisioned into a folder named **NAS (git)**
with `allowUiUpdates: false` — read-only in the UI on purpose. That is
[GAP-1](../architecture-review-2026-08-20.md#gap-1--npm-and-authentik-config-is-click-ops)'s
argument applied here: Grafana's default home for a dashboard is its own SQLite, which is exactly
the unreviewed UI state the NPMplus migration existed to kill.

To iterate: build in any other (hand-made) Grafana folder, then **Dashboard → Export → Save to
file** and commit the JSON into `dashboards/`.

## Retention and sizing

| Store | Retention | Set in |
| ----- | --------- | ------ |
| VictoriaLogs | 90d | `-retentionPeriod` in the compose file |
| VictoriaMetrics | 1y | `-retentionPeriod` in the compose file |

The derived counters are why the two differ: raw request lines age out at 90d, but traffic volume
and status trends stay queryable for a year at a tiny fraction of the disk.

`apps` is a 250GB NVMe with **no redundancy** ([storage.md](../storage.md)). Logs are the only
real growth risk here; metrics at this cardinality run on the order of a gigabyte a year. Revisit
both numbers after a month of real figures rather than guessing now.

## Dependencies

- **`proxy_observability`** — defined by [`stacks/caddy`](../../stacks/caddy/docker-compose.yml)
  like every other `proxy_*` network, consumed here as `external: true`.
- **`proxy_network`** — `victoriametrics` joins it to scrape `crowdsec:6060`.
- **`proxy_downloads`** — `victoriametrics` joins it to scrape the qBittorrent exporter at
  `gluetun:9022` and the SABnzbd exporter at `gluetun:9023`. It runs in gluetun's network namespace (see [downloads.md](downloads.md)), so
  the scraper can also reach the Web UIs there, which is what Caddy on the same network does already.
- **`proxy_arr`** — `victoriametrics` joins it to scrape `exportarr-sonarr`, `-radarr`, `-prowlarr`
  and `-bazarr` on `:9707`. Same trade as `proxy_downloads`: it can also reach those apps' web UIs,
  which Caddy on the same network does already.
- **`proxy_jellyfin`** — `victoriametrics` joins it to scrape `jellyfin-exporter:9594`.
- **`proxy_authentik`** — `victoriametrics` joins it to scrape `server:9300`. Only the
  authentik *server* is scraped; the *worker* is on `authentik_net` alongside Postgres and
  reaching it would mean joining that internal network, which is not worth the blast radius.
- **Tailnet NAS → A1** — the `tor-bridge`, `tor-webtunnel` and `ntp` jobs scrape `100.64.0.13:9035`,
  `:9036` and `:9037`. `snowflake` and `conduit` need no network join: both run on the host network and are
  scraped on `192.168.178.111:9999` and `:9998`.
- **Caddy** writes the log this stack reads, and proxies `grafana.example.com`. CrowdSec reads
  the same file; two readers on one log file is not a conflict.
- **Komodo's clone** at `/mnt/apps/komodo/repos/nas`, pulled by every NAS deploy — see
  [nas-periphery](nas-periphery.md).
- **MaxMind** for GeoLite2. Outbound only, and only from `geoipupdate`.

## Notes

- **CrowdSec's metrics need one host-side edit.** `prometheus.listen_addr` defaults to `127.0.0.1`
  in `/mnt/apps/npm/crowdsec/config/config.yaml`, which is unreachable from another container. Set
  it to `0.0.0.0` and restart the `caddy` stack, or the `crowdsec` scrape job stays down. This was
  already written down as the prerequisite in the
  [crowdsec-console runbook](../runbooks/setup-operations/crowdsec-console.md).
- **Vector will not start until the mmdb files exist.** The enrichment tables are resolved at
  startup, and on a cold bring-up `geoipupdate` has not finished its first download yet. Vector
  crash-loops until it has, then comes up on its own — `restart: unless-stopped` is what makes
  that self-healing rather than an ordering bug. A first deploy that shows `vector` restarting for
  a minute is expected.
- **`_stream_fields` must stay low cardinality.** It is `service,host` — the vhost has ~25 values.
  Adding `client_ip` or `uri` there would create a log stream per client and wreck ingestion
  performance. Those are ordinary fields; they are filterable and groupable without being stream
  fields.
- **Credentials in the query string are redacted before storage.** Jellyfin puts a working
  `api_key=` / `ApiKey=` in most of its URLs, and *App — Detail* groups by `uri` — so without this
  the dashboards would print live API keys on screen. `10-caddy.yaml` rewrites the value of
  `api_key`, `token`, `access_token`, `password`, `secret`, `sig`, `signature` and
  `x-emby-token` to `REDACTED` right after `uri` is read, before `.message` is built from it. Two
  limits worth knowing: it only covers query-string parameters (a credential in a *path* segment
  is not caught), and **events ingested before 2026-09-09 still contain the originals** — purging
  those means wiping the VictoriaLogs data directory, since VictoriaLogs has no delete API.
- **The Prometheus stores hold no request paths at all.** `caddy_requests_total` is tagged with
  vhost/method/status/country only; `uri` and `client_ip` are deliberately log-only. That is a
  cardinality decision first, but it also means the 1y metrics store never accumulates URLs.
- **Caddy names the access logger per site block**, not globally: `http.log.access.log0`,
  `http.log.access.log24`, one `logN` per vhost. The Vector transform therefore prefix-matches
  `http.log.access` — an equality test silently aborts every event, and because `drop_on_error` is
  on, Vector still reports itself perfectly healthy while both stores stay empty. That was the
  first-deploy bug on 2026-09-09.
- **`client_ip` is already the real client on both listeners.** Caddy's `:8443` PROXY-protocol
  listener wrapper rewrites `remote_ip` before the log is written, so no `trusted_proxies`
  handling is needed in Vector. See [caddy.md](caddy.md) → The `:8443` PROXY-protocol listener.
- **GeoIP is skipped for LAN, tailnet and loopback addresses**, which are tagged `country="local"`
  instead. That is what the dashboard's *Off-LAN share* panel counts.
- **`client_ip` is the visitor, not the Cloudflare PoP.** Caddy resolves `CF-Connecting-IP` on the
  public `:8443` listener, so the geo and ASN columns describe the real client. Before that landed
  the orange-clouded names logged a spread of `CLOUDFLARENET` edge addresses whose country was the
  PoP's — see [caddy.md](caddy.md) → Real client IP behind Cloudflare.
- **Uptime Kuma is tagged `country="monitor"`, not by geography.** The A1 VPS Kuma probes every
  public hostname, so it arrives with a public source IP — Oracle's on `:8443`, a Cloudflare edge
  one on `:443` — and it was ~99% of all non-LAN requests, drowning the ~12/day that are real
  outside clients. Vector reroutes any public request whose `User-Agent` starts with `Uptime-Kuma`
  into its own country bucket, and the *Off-LAN share* / *Top countries* / *Off-LAN clients* panels
  exclude it from **both** halves of their ratios. The rows stay queryable: `country="monitor"` in
  metrics, `geo_country:monitor` in LogsQL. LAN-side Kuma is untouched — the public-IP guard runs
  first, so it stays `local`. Each authenticated check logs 2-3 requests, not one, because the
  Authentik redirect chain is followed, which is why `auth.example.com` led every off-LAN panel.
  The *Off-LAN share* numerator carries `or vector(0)`: with Kuma subtracted the remaining outside
  traffic is a dozen requests a day, so the numerator is genuinely empty most of the time and the
  panel would otherwise read *No data* rather than 0%.
- **The VictoriaLogs datasource's `queryType` decides the frame shape, and a wrong one fails
  silently.** A LogsQL query with a `stats` pipe needs `queryType: "stats"`; with `"instant"`,
  `"range"` or `"table"` the plugin returns a *logs* frame (`Time`/`Line`/`labels`, zero
  timestamps) and a table panel renders nonsense rather than erroring. `"logs"` is correct for an
  actual logs panel, and `"statsRange"` — not `"stats"` — for a stats query drawn as a *time
  series* rather than a single number.
- **A grouped `stats` query returns one frame per group per metric, so a table needs
  `labelsToFields` + `merge`, not `reduce`.** `... | stats by (host) count() as requests, ...`
  with five metrics over 30 vhosts comes back as 150 single-point series, each labelled
  `{__name__, host}`. `reduce` turns that into 150 rows. The chain that produces the intended
  30-row, 5-column table is `labelsToFields` (`mode: columns`, `valueLabel: __name__`) → `merge`
  → `organize` to drop `Time`; it works because the plugin stamps every frame in one response
  with the same timestamp, so `merge` joins them on `(Time, host)`. `reduce` stays correct for a
  stat panel whose query has no `by (...)` and therefore returns a single frame. Verified against the live datasource on 2026-09-09 — the *Top clients* panel
  shipped with `"instant"` and had to be corrected. Nothing in CI validates Grafana JSON against
  the plugin the way `caddy validate` covers the Caddyfile.
- **`client_ip` is deliberately not a metric label.** It is unbounded; per-client questions belong
  in VictoriaLogs, which is built for high-cardinality fields.
- **No Authentik SSO on Grafana yet.** It is LAN-only and has its own login, so this is a
  convenience gap rather than an exposure one. Grafana supports generic OIDC when it is worth doing.
- **First ingest backfills the current access log.** `read_from: beginning` reads the unrotated
  `access.log` (up to Caddy's 100MiB roll size) once, so there is history in the UI immediately.
  Rotated `access-*.log` files are not matched, and the checkpoint in `/var/lib/vector` stops a
  restart re-reading anything.

## Operations

> Restart/redeploy go through **Komodo** (Stack `observability`). Over SSH,
> `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …`
> works for inspection. Manual webhook fire:
> `curl -k -X POST https://192.168.178.111:31015/api/stacks/webhooks/<uuid>`.

### Restart / redeploy

- Komodo → Stacks → `observability` → **Restart** or **Deploy**, or push to `stacks/observability/` → the
  runner deploys it through Komodo
  ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). 
- A change to the Vector pipeline, the scrape config or a dashboard arrives with the deploy that its
  push triggers. The containers stay running; each re-reads the file itself. To re-apply one by hand,
  press **Deploy** on the Stack.

### Validating a Vector config change

**There is no CI check for this**, unlike the Caddyfile's `caddy validate` required job. The
enrichment tables need the real mmdb files present, which a GitHub-hosted runner does not have, so
the check would be either fragile or fake. Run it on the NAS instead, against the image the stack
runs and the real `/geoip` directory:

```sh
sudo docker run --rm \
  -v /mnt/apps/komodo/repos/nas/stacks/observability/vector:/etc/vector:ro \
  -v /mnt/apps/observability/geoip:/geoip:ro \
  timberio/vector:<tag from the compose file> \
  validate --no-environment --config-dir /etc/vector
```

`--no-environment` skips sink healthchecks, so this passes without VictoriaLogs running. A VRL
error in a `remap` transform is caught here; a *logic* error in one is not — that shows up as
events silently dropped, because `drop_on_error: true`.

### Upgrade

Renovate bumps all five images by digest like any other stack. Two to read the notes for:

- **VictoriaLogs / VictoriaMetrics** across a major — the on-disk format is backward compatible,
  but downgrading after a major is not always. Snapshot `apps/observability` first.
- **Grafana** across a major — provisioning file schemas occasionally change. The datasource and
  dashboard-provider files are `apiVersion: 1`, which has been stable for a long time.

### Restore from backup

1. Stop the `observability` stack.
2. Restore `apps/observability` from a ZFS snapshot. Losing it is **not** an incident: logs and
   metrics are derived data, and Grafana's own state is only users, preferences and any dashboards
   not yet exported to git.
3. Start the stack.

The parts worth not losing — dashboards, pipeline, scrape config — are in this repo, not in the
dataset.

### Common failures

- **`vector` restart-looping, log says the mmdb path does not exist** → `geoipupdate` has not
  completed a download. Check its logs for a MaxMind auth error before assuming it is timing.
- **Grafana loads but the VictoriaLogs datasource errors** → the plugin did not install.
  `GF_INSTALL_PLUGINS` needs outbound access to grafana.com on first start; check the Grafana
  container log for the plugin fetch.
- **`crowdsec` scrape target down in Grafana** → `prometheus.listen_addr` is still `127.0.0.1`, or
  `victoriametrics` is not on `proxy_network`.
- **Panels empty but Vector looks healthy** → check the VictoriaLogs sink is receiving:
  `curl -s 'http://victorialogs:9428/select/logsql/query?query=service:caddy&limit=1'` from inside
  the stack. An empty result with a happy Vector usually means the remap dropped every event —
  `drop_on_error: true` is silent by design.
- **A dashboard edit will not save** → it is in the git-provisioned **NAS (git)** folder, which is
  read-only on purpose. Copy it to another folder to iterate.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-14
