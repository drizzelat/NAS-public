# Service ideas

Candidate services to self-host next, sized against the hardware we actually have. **Nothing here is
deployed** — this is a shortlist, not a plan. To build one, follow the
[new-service runbook](runbooks/setup-operations/new-service.md) and check ports in
[network.md](network.md) first.

Resource numbers are a snapshot taken 2026-09-15 and drift over time.

## What the hosts can take

| Host | Hardware | Used now | Headroom |
| ---- | -------- | -------- | -------- |
| **NAS** | Intel N100 4C/4T, 32 GB (maxed, one slot), QuickSync iGPU, 1 GbE. `apps` 250 GB NVMe (single disk), `data` 4 TB mirror | 55 containers ≈ 9 GB, ZFS ARC ≈ 12 GB, load avg ≈ 2.2 | 7.3 GB RAM available; `apps` 168 GB free; `data` 1.12 TB free (69 % full) |
| **A1** (`a1-matrix`) | Ampere arm64, 2 OCPU / 12 GB, public IP, Caddy on `:443` | Synapse, Postgres, WhatsApp bridge, Tor bridges, NTP, Kuma, Komodo eval ≈ 2.4 GB | 9.2 GB RAM available; `/opt/matrix` 82 GB free, root 32 GB free |
| **micro** (ingress) | AMD x86, 2 vCPU / 954 MiB, no swap | nginx stream + Komodo periphery (Portainer agent removed 2026-09-17) | ~430 MiB available — **full** |

What that means for placement:

- **NAS: services that live next to the data.** Anything reading or writing the 4 TB mirror, and
  anything LAN-only. Budget roughly **3–4 GB** of new containers: beyond that, memory comes out of
  the ARC and costs ZFS read cache (the CPU is also already half busy). Skip JVM, Elasticsearch
  and headless-Chrome stacks here. `data` gets slow past ~80 % full, which is ~390 GB away. Kiwix
  seeding may still grow ~60 GB into its [300 GB budget](runbooks/setup-operations/kiwix-seeding.md),
  which leaves about **330 GB** for media-growing services.
- **A1: services that must keep working while the NAS or home connection is down**, services that
  need a real public IP (no CGNAT/Tailscale hop), and anything Matrix-related. Needs **arm64**
  images. Right now this is the host with the most spare capacity.
  - The Oracle always-free pool is 4 OCPU / 24 GB, and the A1 uses only half of it. **Resizing
    the A1 in place** (done once before, see [a1-provision](runbooks/setup-operations/a1-provision.md))
    is the way to grow, not a second instance: the free 200 GB block-storage cap is already about
    193 GB used (both boot volumes plus the 100 GB Matrix volume).
- **micro: nothing.** It is the public front door and has no RAM to spare. Keep it a one-job
  failure domain.

Exposure defaults: NAS services start LAN-only (Caddy `lan_only`) and are reached remotely over
Tailscale. Anything streaming audio or video that must be public gets a Cloudflare grey-cloud name,
the way `jellyfin` does, not the orange-cloud SNI path.

## Top picks

### 1. Vaultwarden — NAS

Bitwarden-compatible password manager, and the biggest gap in the current stack.

- **Fit:** ~50–100 MB RAM. Keep it LAN/tailnet-only: never on the public SNI allowlist. Clients
  cache the vault offline, so a NAS outage only blocks syncing and new entries.
- **Backup:** run it on **Postgres**, not the default SQLite. Then the existing `nas.backup.*`
  labels ([postgres-dump](runbooks/backup-restore/postgres-dump.md)) cover it with no new tooling.
- **Watch out:** `ADMIN_TOKEN` goes in the age vault. Disable open signups after creating your
  account.

### 2. Off-NAS alert channel — A1

Today, alerts from inside the estate (NAS Kuma, Grafana) can't be delivered while the NAS itself is
the problem. healthchecks.io covers "everything is dead", but not "Jellyfin is down, tell my phone".
Two options:

- **Matrix room (no new service).** Synapse already runs on the A1, and Kuma and Grafana can both
  post to Matrix. Try this first.
- **ntfy** (~30 MB, arm64). Simple phone push, and scripts can send with a single `curl`. Behind
  the A1 Caddy with auth. Worth it if Matrix notifications turn out too noisy or too slow.

### 3. Audiobookshelf — NAS

Audiobooks and podcasts, with good mobile apps (offline downloads, progress sync). ~150 MB. Library
on the `data` mirror next to Shelfmark's books. Remote access over Tailscale, or grey-cloud if it
must be public.

### 4. Navidrome + Lidarr — NAS

There's no music in the stack yet.

- **Lidarr** joins `media_net` like Sonarr/Radarr. It uses the existing Prowlarr, SABnzbd and
  qBittorrent. `exportarr` supports it, so it drops into the Media stack dashboard. ~200 MB.
- **Navidrome** is Subsonic-compatible (Symfonium, Feishin, Substreamer). ~100 MB.
- **Watch out:** storage, not RAM. A FLAC library of a few thousand albums eats a big share of the
  ~330 GB of `data` headroom. Consider an MP3/Opus-only quality profile in Lidarr.

### 5. More Matrix bridges — A1

Signal, Telegram, Discord or Meta, using the same pattern as `mautrix-whatsapp`. Each needs one
container and a database in the existing Matrix Postgres, so the dump labels cover it. ~50–100 MB
each. The A1 has the room.

## Good fits, lower priority

### NAS

| Service | What it gives you | Cost / note |
| ------- | ----------------- | ----------- |
| **Actual Budget** | Budgeting, syncs across devices | ~100 MB, SQLite files |
| **Radicale** | CalDAV/CardDAV: calendar and contacts off Google/Microsoft | ~30 MB; cheaper alternative to Nextcloud |
| **Miniflux** | RSS reader | ~50 MB + Postgres (dump labels work) |
| **Memos** | Quick notes / journal | ~50 MB |
| **Syncthing** | Continuous phone/laptop folder sync into `data` | ~100 MB; count its growth against `data` |
| **Jellystat** | Jellyfin watch history and stats | ~200 MB + Postgres |
| **Pinchflat** | Archive YouTube channels into the Jellyfin library | ~150 MB; much lighter than TubeArchivist |
| **Stirling-PDF** | Merge/split/OCR/sign PDFs locally, pairs with Paperless | JVM, ~1 GB, so the heaviest item on this list. Only if you'd really use it |
| **Speedtest Tracker** | ISP speed history, evidence for complaints | ~150 MB; schedule a few runs a day, since each one saturates the uplink |
| **Home Assistant** | Smart-home hub | Only if you own devices. ~500 MB, needs host networking for discovery |
| **smartctl_exporter** | Disk SMART history in the existing Grafana | Tiny. Better fit than Scrutiny, which would be a second dashboard next to VictoriaMetrics |
| **NUT exporter** | UPS battery/load in Grafana | Only after buying the UPS noted in [hardware.md](hardware.md); TrueNAS's own UPS service does the shutdown |

### A1

| Service | What it gives you | Why A1 |
| ------- | ----------------- | ------ |
| **changedetection.io** | Alerts on web page changes (prices, restocks, release notes) | Polling and the optional headless browser (~500 MB) stay off the N100 and the home line. Check that the browser image has an arm64 build |
| **Karakeep** | Bookmarks/read-later with full-page archiving and tagging | Chrome + Meilisearch is ~1–1.5 GB, too heavy for the NAS budget and easy for the A1 |
| **Forgejo** (mirror) | Off-GitHub mirror of this repo and others | Survives both a GitHub outage and a NAS outage; the 82 GB volume has room |
| **Minecraft / other game server** | Friends' server with a real public IP | Oracle Ampere is a well-known Minecraft host. Wants the 4 OCPU / 24 GB resize, plus a Security List port |

## Not worth it on this hardware

- **Local LLMs (Ollama + Open WebUI).** The N100 iGPU is useless for inference, and RAM is shared
  with the ARC. On A1 CPUs, small models run at a few tokens per second and consume the free pool.
  Toy at best.
- **Whole-library transcoding (Tdarr/FileFlows).** QuickSync works, but re-encoding a full library
  to HEVC/AV1 on an N100 that's already at load ~2.2 takes weeks. Only worth it for a targeted pass
  over the biggest files, if `data` space gets tight.
- **TubeArchivist.** Elasticsearch alone wants 2 GB+. Use Pinchflat.
- **Nextcloud.** Heavy, and it overlaps filebrowser, Immich and Paperless. If the missing piece is
  calendar/contacts, use Radicale.
- **Self-hosted Healthchecks.** healthchecks.io already covers this
  ([external-heartbeat](runbooks/setup-operations/external-heartbeat.md)), and a dead-man's switch
  hosted inside the estate defeats its own purpose.
- **Komodo.** Already under evaluation on the A1.
- **Anything on the micro VPS.** No headroom, and it should stay a single-purpose failure domain.
