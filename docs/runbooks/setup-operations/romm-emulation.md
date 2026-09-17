# Runbook: Retro/console emulation with RomM

Stand up a self-hosted game library (**RomM**) on the NAS that:

- **serves retro consoles in the browser** (NES/SNES/N64/GB/GBA/GBC/DS/Genesis/PSX…)
  via the built-in EmulatorJS player — **zero install on the client**; and
- **stores the heavy consoles** (GameCube/Wii/Switch) on an SMB share so a **native
  desktop emulator on the client** reads the ROMs directly.

## What emulates where (the important constraint)

The NAS is an **Intel N100, iGPU only, no discrete GPU**
([hardware.md](../../hardware.md)). It therefore **never emulates 3D consoles** — it is a
library + web-delivery host only. Emulation compute lives on the client.

| Console tier | Where it runs | Client needs |
| --- | --- | --- |
| NES/SNES/**N64**/GB/GBA/GBC/DS/Genesis/PSX | EmulatorJS in the **browser** (client CPU/WASM) | just a browser |
| GameCube / Wii | **Dolphin** on the client | a real GPU (any is plenty) |
| 3DS | **Azahar** (Citra successor) on the client | modest GPU |
| **Switch** | **Ryujinx community fork** (Ryubing) or **Citron** on the client | **strong GPU**, your own dumped `prod.keys` + firmware |

> **Client reference for this NAS:** RTX 3050 Ti Laptop, 4 GB VRAM. Retro + Dolphin =
> effortless. Switch runs, but **4 GB VRAM is the ceiling** — mid/light titles play at
> native res; demanding AAA (e.g. TotK) run native-only, no upscaling, and may stutter or
> VRAM-crash. Server-side game streaming (Sunshine/Moonlight) is **not viable on the N100**
> and is intentionally out of scope.
---

## Prerequisites

- Pools: `data` mirror ~1.8 TB free (bulk ROM library), `apps` NVMe (fast config/DB). See
  [storage.md](../../storage.md).
  - **Capacity reality check.** The heavy consoles are big: Wii ISOs 4–8 GB, Switch XCI/NSP
    1–16 GB _each_. A modest Switch/Wii collection eats hundreds of GB fast, and the `data`
    mirror is only single-disk-redundant. **Set a ZFS quota on `data/romm`** (the parent, so one
    cap covers `roms` + `bios`) so a runaway ROM library can't starve `smb_share` and the other
    `data` tenants. **This deployment is capped at 500G** — raise it live with
    `zfs set quota=<n>G data/romm` if the library outgrows it.
- **No metadata API credentials required** — the stack uses Hasheous, which is keyless (Step 3).
- Familiarity with the [new-service runbook](new-service.md) — this runbook is a filled-in
  instance of it plus the emulation specifics.

---

## Step 1 — Create datasets (TrueNAS UI)

**Storage → Datasets → Add dataset.** Follow the repo convention: precious/small on `apps`
(NVMe, nightly-backed-up), bulk/replaceable on `data`.

| Dataset | Holds | Why here |
| --- | --- | --- |
| `apps/romm/db` | MariaDB data | fast NVMe, backed up |
| `apps/romm/config` | RomM config | small, backed up |
| `apps/romm/resources` | fetched metadata/art | backed up |
| `apps/romm/assets` | **user saves + save-states** | precious — must be backed up |
| `apps/romm/redis` | background-task cache | ephemeral, but keep with the stack |
| `apps/romm/dumps` | nightly logical DB dump (Step 10) | backed up — must be a dataset, see below |
| `data/romm` | parent of the library — **carries the quota** (set to **500G**) | one cap covers roms + bios |
| `data/romm/roms` | **ROM/ISO library (bulk)** | big, replaceable, HDD mirror |
| `data/romm/bios` | PSX etc. system files | small, but must be a _sibling_ of `roms` — see below |

> **Create `apps/romm/dumps` before the first dump.** The dump script `mkdir -p`s its target, so
> without the dataset it silently makes a plain directory in `apps/romm`, a parent dataset the
> cloud-sync chain skips (it syncs leaf datasets only). The dumps then never go offsite, which is
> how they sat until 2026-09-11.

RomM expects [**Structure A**](https://docs.romm.app/latest/getting-started/folder-structure/):
`roms/{platform}` and `bios/{platform}` as **siblings** under the library root. `bios/` is _not_
a folder inside `roms/` — put it there and RomM reads `bios` as a platform slug and the scan is
wrong. Folder names must match RomM's
[supported-platform slugs](https://docs.romm.app/latest/platforms/supported-platforms/) exactly —
note **GameCube is `ngc`, not `gc`**:

```text
data/romm/
  roms/
    n64/  snes/  nes/  gb/  gbc/  gba/  nds/  genesis/  psx/   ← browser-playable
    ngc/  wii/                                                 ← Dolphin (SMB)
    switch/                                                    ← Ryujinx-fork (SMB)
  bios/
    psx/                                                       ← system files, per platform
```

**Ownership.** The RomM container has no `PUID`/`PGID` — the image hard-codes user `romm`
**uid/gid 1000** and its nginx workers drop to it. So `chown -R 1000:1000` the `apps/romm/*`
datasets (except `db`, which the MariaDB image chowns itself on first init) and the whole
`data/romm` tree, `chmod 2775` the dirs (setgid, so files dropped in by other writers inherit
group `1000`), and add POSIX ACLs for the other writers:

```bash
sudo setfacl -R -m u:950:rwx  -m d:u:950:rwx  /mnt/data/romm   # truenas_admin = qBittorrent PUID
sudo setfacl -R -m u:3002:rwx -m d:u:3002:rwx /mnt/data/romm   # stefan = the SMB user
```

## Step 2 — SMB share for the heavy consoles

The browser tier needs no share. GameCube/Wii/Switch emulators on the client read ROMs over SMB.

1. **Shares → Windows (SMB) Shares → Add.** Path `/mnt/data/romm/roms`, name e.g. `roms`.
2. Reuse the existing SMB user/permissions pattern from `data/smb_share`
   ([storage.md](../../storage.md)). Read-only is fine for the client emulators (they don't
   write ROMs; saves go to the client or to RomM's `assets`).
3. Map it on the client (Windows `\\192.168.178.111\roms`, or Linux `cifs` mount).

## Step 3 — Generate secrets

Do **not** commit secret values. They ride the encrypted `.env` via the
[secret-sync runbook](secret-sync.md) and are written as Komodo Variables by `scripts/secrets.sh push romm`.

```bash
openssl rand -hex 32   # → ROMM_AUTH_SECRET_KEY
openssl rand -hex 24   # → ROMM_DB_PW      (MariaDB app-user password)
openssl rand -hex 24   # → ROMM_DB_ROOT_PW (MariaDB root password)
```

Add these three to the shared `.env` (secret-sync) — that is the complete set:

| Variable | Purpose |
| --- | --- |
| `ROMM_AUTH_SECRET_KEY` | RomM session signing key (`openssl rand -hex 32`) |
| `ROMM_DB_PW` | MariaDB app-user password (`DB_PASSWD` + `MARIADB_PASSWORD`) |
| `ROMM_DB_ROOT_PW` | MariaDB root password (`MARIADB_ROOT_PASSWORD`) |

> **No metadata credentials needed.** RomM 4.9.2 moved off IGDB as the default provider.
> **Hasheous** (`HASHEOUS_API_ENABLED: "true"`, set in the compose) matches ROMs by hash against a
> curated database and needs **no key, no account, no signup** — it is what the stack uses. IGDB is
> still supported and can be layered on later (`IGDB_CLIENT_ID` / `IGDB_CLIENT_SECRET` from a
> **Twitch** developer app, <https://api-docs.igdb.com/#getting-started>) if you want wider
> coverage of obscure titles; it is not needed for art on mainstream ones. Same for
> `SCREENSCRAPER_*`, `STEAMGRIDDB_API_KEY`, `RETROACHIEVEMENTS_API_KEY`.

## Step 4 — Write the stack

The stack lives at [`stacks/romm/docker-compose.yml`](../../../stacks/romm/docker-compose.yml) —
**read it there**, it is the single source of truth for the images and their `tag@sha256` pins.
It follows the usual repo conventions (`restart: unless-stopped`, `no-new-privileges`,
healthchecks, `deploy.resources.limits`, config on `/mnt/apps`, bulk on `/mnt/data`, the
`proxy_romm` external network). The decisions worth knowing before you touch it:

- **Two library mounts, not one.** `/mnt/data/romm/roms → /romm/library/roms` and
  `/mnt/data/romm/bios → /romm/library/bios`, so Structure A (Step 1) holds. They are separate
  bind mounts because ROMs are bulk (`data`) and everything else is precious (`apps`). RomM
  hardlinks inside the library where it can and falls back to a copy on `EXDEV`
  (`backend/utils/filesystem.py: link_or_copy_file`), so splitting across pools is safe.
- **`HASHEOUS_API_ENABLED: "true"`** is the metadata provider. No key (Step 3).
- **RomM's healthcheck uses `wget`, not `curl`** — the image is `nginx:alpine`-based and has no
  curl. `/api/heartbeat` is unauthenticated.

> **RomM needs MariaDB, not plain MySQL.** RomM bundles its own Redis (the `/redis-data` mount — true
> of 4.9.2 at bring-up and of the pinned release), so no separate Redis/Valkey container is needed — **but this is version-specific**:
> the RomM _dev_ compose uses a separate `valkey` service, and a future release could move
> Redis back out of the image. Check the release notes on every major upgrade; if a version
> stops bundling Redis, tasks (scan/metadata) silently queue and never run, and you must add a
> `valkey` container + `REDIS_HOST`. Internal HTTP port is **8080** — no host port is published;
> Caddy reaches it over `proxy_romm` (Hub-and-spoke, per [network.md](../../network.md)).

> **MariaDB memory.** The DB limit is **1G, not 512M.** A metadata scan of a large library
> plus InnoDB buffer/connections can push MariaDB past 512M, and a Docker hard limit is an
> **OOM-kill mid-scan**, not graceful back-pressure. Watch the first big scan; if the DB
> restarts, raise the limit further or add a small `my.cnf` (mounted at
> `/etc/mysql/conf.d/`) capping `innodb_buffer_pool_size`.

> **DB password rotation is a trap.** `MARIADB_USER` / `MARIADB_PASSWORD` are applied **only on
> first init** (empty datadir). If you later rotate `ROMM_DB_PW` via secret-sync, the env
> updates in both containers but the **existing** MariaDB user password does not change — RomM
> then fails to authenticate and it looks like "wrong creds." To actually rotate: exec into
> `romm-db` and `ALTER USER 'romm'@'%' IDENTIFIED BY '<new>';` (matching the new env), or wipe
> the `apps/romm/db` datadir to force a clean re-init. The root password (`ROMM_DB_ROOT_PW`) has
> the same constraint.

## Step 5 — Proxy network + Caddy vhost

1. `proxy_romm` is defined by the `caddy` stack
   ([`stacks/caddy/docker-compose.yml`](../../../stacks/caddy/docker-compose.yml), Step 6) — it
   must exist **before** RomM starts.
2. **No DNS record needed.** AdGuard already holds a **wildcard** rewrite
   `*.example.com → 192.168.178.111`, so `romm.example.com` resolves on the LAN/tailnet the
   moment the vhost exists. (Verify: `nslookup romm.example.com`.)
3. **Caddyfile** ([`stacks/caddy/Caddyfile`](../../../stacks/caddy/Caddyfile)) — the same LAN-only
   shape every other internal service uses:

   ```caddyfile
   romm.example.com, https://romm.example.com:8443 {
   	import edge_log
   	import lan_only http://romm:8080
   }
   ```

   The existing `*.example.com` wildcard certificate covers it, and websockets (netplay, live
   scan progress) need no toggle in Caddy. Add `romm` to `LAN_ONLY_HOSTS` in
   [`edge-access-policy.yml`](../../../.github/workflows/edge-access-policy.yml) and to
   [network.md](../../network.md) → Access control.

> **Do NOT add COOP/COEP headers in the Caddyfile.** EmulatorJS needs `SharedArrayBuffer`, which requires a
> **cross-origin-isolated** page — but RomM already handles this itself, and it does so
> _selectively_: its internal nginx sets `Cross-Origin-Opener-Policy: same-origin` +
> `Cross-Origin-Embedder-Policy: require-corp` **only on the player routes** (`/rom/*/ejs` and
> `/console/rom/<id>/play` — see the `map $request_uri` in its `default.conf.template`) and sends
> **no** such headers anywhere else. That is deliberate: `require-corp` on the whole app would
> block the cross-origin box art. Adding the headers globally with a Caddyfile `header` directive
> therefore breaks things **two** ways — it duplicates them on the player route (duplicate COOP/COEP
> is itself an isolation failure) and it isolates every other page. Caddy's only job is to **pass
> them through**, which it does. Verify rather than assume: in the browser's dev tools, a player
> page (`/rom/<id>/ejs`) carries both headers and the library page carries neither.
>
> HTTPS is the other hard requirement for `SharedArrayBuffer`; every Caddy vhost serves it.

> **The Tailscale range is already covered.** The `lan_only` snippet's `@lan` matcher is
> `remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10` minus the ingress VPS's tailnet IP — the
> `100.64.0.0/10` entry is the Tailscale CGNAT range, so remote tailnet clients pass. (A
> purely-LAN rule would silently block them, since a Tailscale client's source IP is _not_ on the
> LAN subnet.)

> **Auth choice.** RomM has its own login (first-run admin, Step 7). Native auth + LAN/Tailscale
> gating is enough. Authentik SSO/OIDC is optional and can be layered later like
> [Mealie](mealie-authentik-oidc.md) — not required for first bring-up. RomM does support OIDC
> (`OIDC_*` env, see its `env.template`).

## Step 6 — Deploy

RomM has env in the vault, and CI holds no vault key, so the stack is created from a workstation
(when RomM was first deployed on 2026-07-13 CI still held the key and did all of this on the push):

1. Push `stacks/romm/` with its `secrets.enc/portainer-env/romm.env.age`, together with (or after)
   the `proxy_romm` network and vhost in `stacks/caddy/` — **`proxy_romm` must exist before RomM
   starts**. `deploy-stacks` redeploys `caddy` and stops at `romm` with
   `is NEW and its env lives in the vault` — expected.
2. `scripts/secrets.sh push romm` — creates the stack from `main` with its env.
3. `gh workflow run deploy-stacks.yml -f stacks=romm` — health-checks it. Later pushes fire the
   webhook it has.

The workflow discovers the stack→webhook map live from `GET /api/stacks`; there is nothing to
register by hand ([portainer-webhook-deploy](portainer-webhook-deploy.md)).

## Step 7 — First run

1. Open `https://romm.example.com` → create the **admin** account (first user).
   **Do this immediately after first boot** — RomM has no pre-seeded admin, so _whoever hits
   the URL first claims it_. Even LAN/Tailscale-gated, don't leave a fresh instance sitting
   un-claimed.
2. Drop a couple of ROMs into the matching `data/romm/roms/<platform>/` folders.
3. RomM → **Scan** (or wait for the filesystem-change rescan). Confirm art/metadata pull from
   Hasheous. If art is missing, see *No box art* in Troubleshooting.
   > **Don't trust instant detection for bulk imports.** `ENABLE_RESCAN_ON_FILESYSTEM_CHANGE`
   > watches the bind mount via inotify. A large batch SMB copy can fire the watcher mid-copy
   > (scanning a half-written file) or drop events under a flood. After a bulk import, run a
   > **manual Scan** once the copy finishes; `ENABLE_SCHEDULED_RESCAN` is the backstop, not the
   > primary path.
4. Play a retro title in the browser to confirm EmulatorJS works end-to-end. If it hangs on
   `SharedArrayBuffer`, fix the COOP/COEP headers (Step 5) before moving on.

## Step 8 — Fill the library (ROM acquisition)

RomM is a **library manager, not a downloader** — it never fetches ROMs itself. Three paths feed
it:

| Tier | Source | Mechanism |
| --- | --- | --- |
| Retro (browser tier) | **Internet Archive** (No-Intro / Redump set items) | `aria2c` HTTP, or the item's `.torrent` via qBittorrent, into `data/romm/roms/<platform>/` (8a) |
| GameCube / Wii / Switch | **Prowlarr + qBittorrent** (the `arr` + `downloads` stacks) | manual search → grab, seeds in place (8b) |
| Usenet (any tier) | **Prowlarr + SABnzbd** (the `arr` + `downloads` stacks) | manual search → grab into `/data`, then move into the library (8c) |

> **Myrient is dead.** It shut down **2026-03-31** — donations flat against the AI-driven RAM/SSD
> price spike, ~$6 k/month out of the maintainer's pocket. Old copies of this runbook pointed
> `aria2c` at `myrient.erista.me`; that host is gone, so use Step 8a instead. Successor mirrors
> (Romheaven, Vimm's Lair) exist but none republish the full verified sets as a plain directory
> listing the way Myrient did — the Internet Archive does, and it is what 8a uses.
>
> **Why there is no `*arr` for ROMs here.** Prowlarr indexes torrent/Usenet **trackers**.
> Trackers carry PC repacks, Switch NSP/XCI and Wii/GC ISOs — they do **not** carry per-title
> retro ROMs; those live in curated archive/set mirrors (No-Intro / Redump). So an arr-style
> "monitor + auto-grab" loop simply has nothing to search for the browser tier.
> **Questarr** (already running in the `arr` stack) is **PC-games only** — no console
> ROMs, no RomM link; don't expect it to feed this library.
> [**Gamarr**](https://github.com/JeremiahM37/gamarr) is the one project that does the whole job
> (Prowlarr + set-mirrors + Vimm's Lair → qBittorrent/SABnzbd, auto-sorts by platform, links
> items to RomM), but as of 2026-07 it is a single-maintainer project with ~11 stars, no image
> provenance, and its Myrient scraper is now dead upstream — **not adopted here.** Re-evaluate
> later; it targets the same `roms/<platform>/` layout, so it drops in without restructuring.

Whatever the path, only **you** can judge whether you are entitled to the media — the mirrors
and trackers below host copyrighted ROMs regardless of what you own.

### Step 8a — Internet Archive (retro tier)

With Myrient gone, the **Internet Archive** is the remaining place that carries the verified
**No-Intro** (cartridge) and **Redump** (disc) sets whole. It is not a directory mirror — sets are
uploaded as _items_, one item holding one set, and item identifiers change as uploads are taken
down and re-mirrored. So the first move is always **find the item**, not run a fixed URL.

Two ways to pull from an item, and the choice matters:

| Way | When | Why |
| --- | --- | --- |
| **Item `.torrent` → qBittorrent** | you want a whole set, or the item is big | goes through **gluetun**, resumes, and the Archive seeds it — preferred |
| **`aria2c` per file** | you want a handful of titles | no client, but egresses from the **WAN IP** (below) |

```bash
# 1. FIND the item. Browse/search (in a browser, or `ia search`):
#      https://archive.org/search?query=no-intro+super+nintendo
#      https://archive.org/search?query=redump+playstation
#    Note the identifier from the URL: archive.org/details/<identifier>

ITEM=<identifier>

# 2. See what's inside before you pull tens of GB.
curl -s "https://archive.org/metadata/$ITEM" | jq -r '.files[] | "\(.size)\t\(.name)"'

# 3a. Whole set -> torrent, through the VPN. Grab the item's torrent and add it in
#     qBittorrent with save path /roms/<platform> (Step 8b sets that mount up).
#       https://archive.org/download/$ITEM/${ITEM}_archive.torrent

# 3b. A few titles -> direct HTTP. Put the exact filenames in /tmp/want.txt first.
DEST=/mnt/data/romm/roms/snes
sed "s|^|https://archive.org/download/$ITEM/|" /tmp/want.txt > /tmp/urls.txt
aria2c -d "$DEST" -i /tmp/urls.txt --continue=true \
  --max-concurrent-downloads=2 --max-connection-per-server=2
```

- **Full sets are huge.** A No-Intro cartridge set is tens of GB, a Redump disc set can be
  hundreds. `data/romm` is quota-capped at **500G** (Prerequisites) — cut the list down, or raise
  the quota deliberately.
- **`aria2c` on the host does not go through gluetun.** The VPN kill-switch only covers
  qBittorrent/SABnzbd/FlareSolverr ([downloads.md](../../services/downloads.md)); a host-side
  `aria2c` run egresses from your **WAN IP**. The torrent path (3a) does not have this problem —
  that is the main reason to prefer it.
- **Ownership.** `aria2c` run as root leaves root-owned files RomM (uid 1000) can't read —
  `chown -R 1000:1000` the platform folder after, or run as a user that owns it (Step 1). That's
  the "Permission denied on library" row in Troubleshooting.
- **Items disappear.** Takedowns happen; an identifier that worked last month may 404. Re-search
  rather than assuming the set moved to a predictable path.
- **Cartridge sets ship as `.zip`** — RomM/EmulatorJS read those directly, leave them zipped.
  **Redump disc sets ship as `.cue`+`.bin` / `.iso`** — convert to `.chd` with `chdman` before
  import (much smaller, and what the PSX core wants).
- Finish with a **manual Scan** in RomM (Step 7.3) — do not rely on the inotify rescan for a
  bulk import.

### Step 8b — Prowlarr manual grab (heavy consoles)

Reuse the existing stacks — Prowlarr is in `arr`, qBittorrent is in `downloads`, and qBittorrent is
already behind gluetun. Two prerequisites, then it's a manual workflow.

**1. qBittorrent's path into the ROM library.** Already in the compose — the `qbittorrent` service
in [`stacks/downloads/docker-compose.yml`](../../../stacks/downloads/docker-compose.yml) binds
`/mnt/data/romm/roms:/roms` alongside its own `/data`. Without it the container physically cannot
write into the library.

> Downloads and RomM's library sit on **different datasets**, so "download to mediaserver, then
> move" is a full **copy**, not a rename — and it breaks seeding. Download **directly into**
> `/roms/<platform>` instead and seed in place. (Usenet has no seeding, so 8c does the opposite.)
>
> The dataset must exist **before** the stack redeploys. If `/mnt/data/romm/roms` is missing,
> Docker creates the bind source as an empty **root-owned** dir and qBittorrent (`PUID=950`)
> silently can't write to it. Step 1's `setfacl -m u:950:rwx` is what makes this mount usable.

**2. Point qBittorrent's category at it.** qBittorrent → Categories → add `roms`, save path
`/roms`. Keep **"Keep incomplete torrents in"** set to the existing
`/data/torrents/incomplete` — partial files must never appear inside the RomM library, or the
filesystem-change rescan indexes a half-written ISO.

**3. Grab.** Prowlarr → **Settings → Download Clients** → add qBittorrent (host `gluetun`, port
**8082** — it shares gluetun's netns, and the compose sets `WEBUI_PORT=8082`) with category
`roms`. Then **Search** tab → query the title → filter to the console category → **Grab**. Set the
save path per-platform (`/roms/switch`, `/roms/wii`, `/roms/ngc`) on the torrent, or sort after
the fact.

- **Nothing is automated.** No monitoring, no RSS, no quality profiles — Prowlarr's Search tab is
  a manual one-off tool. That is the whole feature here.
- **Releases are often `.rar`/`.7z`/multi-part.** `unpackerr` only watches Sonarr/Radarr queues,
  not this — extract by hand into the platform folder.
- Then **manual Scan** in RomM, same as 8a.

### Step 8c — Usenet / NZB grab (SABnzbd)

SABnzbd is already in the `downloads` stack and already behind gluetun, so the NZB path needs
**no compose change at all** — and deliberately so. The rule from 8b inverts here:

> **Do not point SABnzbd at the RomM library.** SABnzbd downloads and unpacks into its
> _incomplete_ dir, then **moves** the finished job to the category folder. `data/mediaserver` and
> `data/romm` are different datasets, so that move is a cross-filesystem **copy** — during which a
> **partially-written file sits inside the library**, exactly what RomM's
> `ENABLE_RESCAN_ON_FILESYSTEM_CHANGE` watcher then indexes as a broken 0-byte title. There is no
> seeding obligation on Usenet, so nothing is lost by finishing in `/data` and moving afterwards.

1. **Usenet provider.** SABnzbd needs a server (block or unlimited account) — it is the same one
   Sonarr/Radarr already use if you have it configured; check **SABnzbd → Config → Servers**. No
   provider, no downloads, however many indexers you add.
2. **NZB indexers in Prowlarr.** Prowlarr → **Indexers → Add** → the Usenet ones you have accounts
   for (NZBGeek / NZBPlanet / DrunkenSlug / …). Prowlarr → **Settings → Download Clients** → add
   **SABnzbd** (host `gluetun`, port **8080**, API key from SABnzbd → Config → General), category
   `roms`.
3. **SABnzbd category.** SABnzbd → Config → Categories → add `roms` with folder
   `roms` — relative, so it lands under the existing complete dir inside `/data`. **Not** `/roms`.
4. **Grab.** Prowlarr → **Search** → title → **Grab**. It downloads and unpacks in `/data`.
5. **Move into the library, then scan:**

   ```bash
   # on the NAS, once SABnzbd reports the job complete
   SRC=/mnt/data/mediaserver/data/usenet/complete/roms/<job>
   DEST=/mnt/data/romm/roms/switch          # or wii / ngc / psx …

   rsync -a --info=progress2 "$SRC"/*.nsp "$DEST"/    # copy only the payload, not .nzb/.par2/.sfv
   chown -R 1000:1000 "$DEST"                          # RomM's uid — see Step 1
   ```

   Then **manual Scan** in RomM.

- **Usenet coverage for console ROMs is thin.** Retention-wise it is great for **Switch NSP/XCI**
  and PC, patchy for Wii/GC ISOs, and essentially absent for per-title retro ROMs — those are the
  Internet Archive's job (8a). Do not expect the NZB path to fill the browser tier.
- **`unpackerr` does not help here** — it watches Sonarr/Radarr/Lidarr queues only. SABnzbd's own
  post-processing unpacks the `.rar`/`.7z`; anything it leaves behind, extract by hand.
- **Only the payload moves.** Copying the whole job dir drags `.par2`/`.nzb`/`.sfv` into the
  library; RomM will list them as junk entries. Filter on the real extension, as above.

## Step 9 — Client setup (heavy consoles)

Browser tier needs nothing. For the SMB tier, install on the client and point each emulator's
game path at the mapped `roms` share:

- **GameCube/Wii → Dolphin** (<https://dolphin-emu.org>): add `\\NAS\roms\ngc` and `…\wii`.
- **3DS → Azahar** (Citra successor): add `…\` for your 3DS dumps.
- **Switch → Ryujinx community fork (Ryubing)** or **Citron**: install `prod.keys` +
  `title.keys` + firmware (dumped from **your** console) into the emulator's key/firmware dirs,
  then add `\\NAS\roms\switch` as a game directory. Expect 4 GB-VRAM limits on this client.

Saves: browser/EmulatorJS saves live in RomM (`assets`, backed up). Native-emulator saves live
on the client — back those up separately if they matter.

## Step 10 — Docs + backups

- Copy `docs/services/_template.md` → `docs/services/romm.md`, fill in (URL, port 8080, volumes,
  env, depends-on MariaDB). Add a row to `docs/services/README.md`.
- `docs/network.md`: add the `proxy_romm` network row. No new LAN host port (proxied). Note the
  SMB share if you track shares there.
- `docs/storage.md`: add the bind mounts (`/mnt/apps/romm/{db,config,resources,assets,redis}`,
  `/mnt/data/romm/roms`) to the shares/bind-mounts table.
- **Add the DB to the nightly logical dump — this is required, not optional.** A ZFS snapshot of
  the live MariaDB datadir is only crash-consistent; a logical `mariadb-dump` is the safe,
  version-independent restore path for a DB that holds your **precious saves + metadata**.
  `romm-db` carries the `nas.backup.*` labels (engine `mariadb`) that
  [`scripts/pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) discovers, and is in the
  [DB dump runbook](../backup-restore/postgres-dump.md) table — after first bring-up, **run the
  script once by hand and confirm a clean `romm` dump lands in `/mnt/apps/romm/dumps`.** The
  nightly Hetzner push ([backup runbook](../backup-restore/backup.md)) carries the saves
  (`apps/romm/assets`) and the dumps (`apps/romm/dumps`, Step 1) offsite.
- Add a Homarr tile and (optional) a Kuma monitor for `romm.example.com`.

## Operations

- **Restart/redeploy:** Komodo → Stacks → `romm` → **Restart** / **Deploy**, or push to
  `stacks/romm/`, which deploys it through `deploy-stacks`.
- **Upgrade:** Renovate opens the PRs ([romm.md](../../services/romm.md) → Upgrade). Read RomM
  release notes for DB-migration warnings; rollback = revert the commit + redeploy.
  - **MariaDB majors are one-way.** The stack has been on the 12.x line since 2026-07-16 (11.4 LTS
    at bring-up). Crossing a major does a **one-way datadir upgrade with no downgrade path**: take a
    fresh logical dump first, and be ready to reload it into the new major if the in-place upgrade
    goes wrong. `mariadb` bumps are on the sweep's `MERGE_SKIP_IMAGES`, so they wait for a hand-merge.
  - **Redis externalization watch.** If a RomM release stops bundling Redis (see the MariaDB/Redis
    note in Step 4), the upgrade needs a new `valkey` container + `REDIS_HOST` or background tasks
    stop running.
- **Restore:** stop stack → restore `apps/romm/*` (config, db, **assets/saves**) from ZFS
  snapshot or Hetzner → start. ROMs (`data/romm/roms`) are replaceable — re-copy if lost. If the
  snapshotted datadir won't come up cleanly (crash-consistent state), fall back to the logical
  dump: reload `/mnt/apps/romm/dumps/romm_<stamp>.sql.gz` into `romm-db` per the
  [DB dump runbook](../backup-restore/postgres-dump.md).

## Troubleshooting

| Symptom | Cause → fix |
| --- | --- |
| RomM won't start, DB errors | MariaDB not healthy / wrong creds. Confirm `ROMM_DB_PW` matches in both services; check `romm-db` healthcheck; **MySQL image won't work — must be MariaDB**. |
| RomM auth fails _after a secret rotation_ | Rotated `ROMM_DB_PW` didn't reach the DB — the user password is set only at first init. `ALTER USER 'romm'@'%'` in `romm-db` to match, or wipe `apps/romm/db` to re-init (Step 4 note). |
| `romm-db` keeps restarting mid-scan | OOM-killed at the memory limit. Raise the `1G` limit or cap `innodb_buffer_pool_size` via `my.cnf` (Step 4 note). |
| No box art / metadata | Hasheous matches by **file hash** — a bad dump, a re-zipped ROM or a renamed-but-modified file simply won't match. Confirm `HASHEOUS_API_ENABLED=true` is live in the container env, then check RomM → the title → "Manual match". Persistent gaps = add IGDB (Step 3). |
| Games not detected on scan | Wrong platform folder name — match RomM's supported-platform slugs (**GameCube is `ngc`, not `gc`**). Also: `bios/` must be a sibling of `roms/`, not inside it (Step 1). Also: bulk SMB import may need a manual Scan (inotify race, Step 7). |
| Browser emulator won't launch a title | If it's GC/Wii/Switch: native-only via SMB, by design. If it's a _supported_ retro console hanging on `SharedArrayBuffer`: page isn't cross-origin-isolated — check HTTPS + COOP/COEP headers reach the browser and Caddy isn't stripping/duplicating them (Step 5). |
| Scan/metadata tasks queue but never run | Redis not reachable. The pinned release bundles it (`/redis-data`); after an upgrade that externalized Redis, add a `valkey` container + `REDIS_HOST` (Step 4 note). |
| Reachable on LAN, not over Tailscale | `100.64.0.0/10` missing from Caddy's `@lan` matcher, or the tailscale stack lost `--snat-subnet-routes=false` (Step 5). |
| Switch title stutters / crashes | 4 GB VRAM ceiling on the client. Drop to native res, disable upscaling, or accept it's too heavy for this GPU. |
| Permission denied on library | RomM container UID can't read `data/romm/roms` — align dataset ownership/ACL with the SMB user (see [storage.md](../../storage.md)). |
| Grabbed torrent finishes but RomM never sees it | qBittorrent has no bind mount into the ROM library, so it saved to `/data` instead. Add `/mnt/data/romm/roms:/roms` to the `qbittorrent` service and redeploy `downloads` (Step 8b). |
| RomM lists a broken/0-byte title after a grab | qBittorrent wrote an **incomplete** file inside the library and the rescan indexed it. Point "Keep incomplete torrents in" at `/data/torrents/incomplete`, delete the stub, re-Scan (Step 8b). |
| Archive.org set 404s / item vanished | Takedown or re-upload under a new identifier. Re-search `archive.org` rather than reusing the old path (Step 8a). Myrient, the old source, is **shut down since 2026-03-31**. |
| NZB job finished but RomM never sees it | By design — SABnzbd finishes in `/data`; the move into `roms/<platform>` is a manual `rsync` + `chown 1000:1000`, then Scan (Step 8c). |
| RomM lists `.par2` / `.nzb` / `.sfv` entries | Whole SABnzbd job dir was copied into the library instead of just the payload. Delete the junk, re-Scan (Step 8c). |
| Prowlarr can't reach qBittorrent/SABnzbd | Wrong port. Both share gluetun's netns: qBittorrent is **8082** (`WEBUI_PORT`), SABnzbd **8080**. Host is `gluetun`, not the container name. |

## Last updated

2026-09-11
