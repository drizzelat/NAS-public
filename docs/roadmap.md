# Roadmap

Work that is **decided in principle but not built**. This is the queue; it is not a promise, and
nothing here exists on the estate yet.

Three neighbours, so this file stays small:

| File | Holds |
| ---- | ----- |
| [service-ideas.md](service-ideas.md) | The candidate shortlist — sized against the hardware, *nothing chosen* |
| This file | Items that graduated from that list, plus the non-service work (hardware, CI) |
| [runbooks/](runbooks/) | Anything already built, or planned in enough detail to execute step by step |

An item leaves this file when it lands: a stack gets `docs/services/<name>.md`, a procedure gets a
runbook, and the row here is deleted. An item with a real design question in it belongs in a runbook
of its own before it is built ([cloudflare-tunnel-cutover.md](runbooks/setup-operations/cloudflare-tunnel-cutover.md)
is the shape: designed, nothing built).

## Queue

| # | Item | Host | Blocked on | Size |
| - | ---- | ---- | ---------- | ---- |
| [1](#1-syncthing-instead-of-the-smb-shares) | Syncthing instead of the SMB shares | NAS | Nothing | Medium |
| [2](#2-vaultwarden--the-placement-is-the-decision) | Vaultwarden | **undecided — NAS or A1** | The placement decision below | Small |
| [3](#3-bookmarks--linkwarden-or-karakeep) | Bookmarks / read-later (Linkwarden or Karakeep) | A1 | arm64 check, Linkwarden vs Karakeep | Small |
| [4](#4-calendar-and-contacts-caldav) | Calendar + contacts (CalDAV) | NAS | Radicale vs Baikal | Small |
| [5](#5-raspberry-pi--secondary-dns) | Raspberry Pi as secondary DNS | new host | Hardware, **AdGuard config sync**, failover shape | Medium |
| [6](#6-ups) | UPS | NAS | Hardware choice | Small |
| [7](#7-staging-for-the-deploy-workflows) | Staging for the deploy workflows | runner VM / A1 | Scope decision below | Medium–High |
| [8](#8-host-and-container-metrics-to-alert-on) | Host and container metrics to alert on | NAS | Beszel's own alerts vs new exporters | Medium |
| [9](#9-hdd-expansion--a-media-pool) | HDD expansion: second SATA card + a `media` pool on 4× 12–16 TB RAIDZ2 | NAS | Buying the card and drives (not urgent, `data` ~65% full) | Medium |
| [10](#10-dawarich--a-self-hosted-location-timeline) | Dawarich — Google Maps Timeline replacement | NAS | Reverse-geocoding choice; PostGIS in the dump path | Medium |

Two cross-cutting rules that decide several of these:

- **Anything hosted on the A1 for independence must not depend on the NAS.** The A1's value is that
  it keeps working while the house is dark. An A1 app that logs in through Authentik
  ([authentik.md](services/authentik.md)) — which runs on the NAS — throws that away. Items 2 and 3
  both hit this.
- **New LAN ports go in [network.md](network.md) before the stack merges**, and new bind mounts in
  [storage.md](storage.md); CI's `docs-drift` job fails the push otherwise
  ([AGENTS.md](../AGENTS.md)).

---

## 1. Syncthing instead of the SMB shares

**Why.** The TrueNAS SMB service (`:445`, not a stack) serves the two per-user shares and `shared`
out of `/mnt/data/smb_share`, and it misbehaves: hung mounts, stale handles, credential churn on the
clients. Syncthing replaces the *mount* with a **sync**: each device keeps a local copy, works
offline, and nothing blocks when the NAS is away.

**Shape.** One `syncthing` stack on the NAS, one folder per share, `send-receive`, NAS acting as the
always-on node. Devices reach it on the LAN, or over Tailscale from outside — no public name.

**What must be true before it replaces anything**

- **Syncthing is not a backup.** A deletion on the phone is a deletion on the NAS. Enable **staggered
  file versioning** on the NAS side, and keep the nightly Hetzner sync of `data/smb_share`
  ([backup.md](runbooks/backup-restore/backup.md)) — then decide whether `.stversions` is in or out
  of that sync, since it is the one thing that grows without bound.
- **Ownership.** `/mnt/data/smb_share` is UID/GID **568** so that SMB and `files` (FileBrowser
  Quantum, [files.md](services/files.md)) see the same tree. Syncthing must write as 568 too, or the
  web UI and any surviving share start seeing files they cannot touch.
- **Conflicts change shape.** SMB is last-writer-wins; Syncthing leaves `*.sync-conflict-*` files
  next to the original. Someone has to look at those occasionally.
- **`roms` stays SMB.** Native GameCube/Wii/Switch emulators read ROMs over the share directly
  ([romm.md](services/romm.md)); syncing that library onto a client is not the same feature. Item 1
  is about `smb_share`, not about turning the SMB service off.
- **Don't cut over.** Run Syncthing beside SMB, move one folder, live on it for a few weeks, then
  retire shares one at a time. There is no rollback cost to having both.

**Ports it needs** (all new rows in [network.md](network.md)): `22000/tcp` + `22000/udp` (QUIC) for
sync, `21027/udp` for local discovery. The GUI (`8384`) stays container-internal behind a `lan_only`
Caddy vhost; Syncthing has its own GUI password, so no Authentik application is needed. Disable
global discovery and relaying if every device is on the LAN or the tailnet — otherwise the NAS
announces itself to the public discovery servers for no benefit.

**Docs when it lands:** new stack + `docs/services/syncthing.md`, ports in `network.md`, mounts in
`storage.md`, the versioning decision in `backup.md`, the storage diagram in
[architecture.md](architecture.md), and a line in `files.md` saying both serve the same tree.

## 2. Vaultwarden — the placement is the decision

Already the top pick in [service-ideas.md](service-ideas.md#top-picks), which assumed the
NAS. That assumption is the thing to re-check, because of one dependency:

> **[disaster-recovery.md](runbooks/incident-response/disaster-recovery.md) and
> [restore-drill.md](runbooks/backup-restore/restore-drill.md) both start with "get these secrets out
> of Bitwarden"** — the rclone crypt password and salt, the Hetzner Storage Box credentials, the
> TrueNAS config passphrase. If Vaultwarden becomes the vault that holds those, and it runs on the
> NAS, then restoring the NAS requires a secret that is only inside the NAS. That is circular, and it
> is the failure mode where you need it most.

| | NAS | A1 |
| - | --- | -- |
| Reachable when the NAS is down | No (clients keep a cached, read-only-in-practice copy) | Yes |
| Reachable when the home line is down | Only from inside the house | Yes |
| Exposure | LAN/tailnet only, never on the public SNI allowlist | A public auth surface on the internet-facing host |
| Backup | New stack + `nas.backup.*` labels ([postgres-dump](runbooks/backup-restore/postgres-dump.md)) | Reuse the Matrix Postgres; its dumps already pull to the NAS nightly ([a1-matrix-backup](runbooks/backup-restore/a1-matrix-backup.md)) |
| arm64 | n/a | Verify the image manifest first |

**Recommendation: the A1**, *if* it is meant to hold the disaster-recovery secrets. Both hosts are
fine if it is only for day-to-day logins and cloud Bitwarden keeps the DR key set.

Whichever host wins, two things are not optional: a **break-glass copy of the DR secrets that is not
Vaultwarden** (cloud Bitwarden, or a printed sheet in a safe — say which, in
`disaster-recovery.md`), and **no self-service signups** after the first account. On the A1, do not
put it behind NAS Authentik — see the cross-cutting rule above; use Vaultwarden's own accounts plus
`ADMIN_TOKEN` in the age vault.

## 3. Bookmarks — Linkwarden or Karakeep

Same job: save a link, archive the page so it survives link rot, tag and search it.
[service-ideas.md](service-ideas.md) lists **Karakeep** on the A1; **Linkwarden** is the other
candidate and the reason this row exists.

- **Both are a web app + Postgres + a headless-Chromium worker**, optionally Meilisearch. That is
  ~1–1.5 GB with the browser, which is why it goes on the **A1** and not on the N100 — the same
  reasoning `service-ideas.md` applies to changedetection.io.
- **Check the arm64 manifest for every image in the compose before committing**, the worker image
  included. A missing arm64 build is what forces the whole thing back onto the NAS budget.
- **Postgres means the existing dump labels cover the metadata.** The *archives* (a PDF and a
  screenshot per link) are files, not rows — they need their own line in the A1 backup and a size
  budget against the 82 GB volume.
- **Auth: its own accounts, not NAS Authentik** (cross-cutting rule). Both projects support OIDC, so
  this is a deliberate choice, not a limitation.

Pick on the feature that matters to you — Linkwarden leans on collections and link archiving,
Karakeep on the AI-tagging and full-text side. For a single user either is fine; do not run both.

## 4. Calendar and contacts (CalDAV)

Nextcloud stays rejected ([service-ideas.md](service-ideas.md#not-worth-it-on-this-hardware)); the
missing piece is CalDAV/CardDAV, not groupware.

| Option | Cost | Trade-off |
| ------ | ---- | --------- |
| **Radicale** | ~30 MB, plain files on disk | No web UI at all — clients only, config file + htpasswd |
| **Baikal** | PHP + SQLite, ~100 MB | Small web admin for users and address books; heavier, and PHP |

Either way:

- **NAS, LAN/tailnet-only.** Phones sync over Tailscale, the same way everything else is reached
  from outside; no public name. A calendar client that cannot reach the server just retries, so this
  is cheap.
- **No Authentik.** CalDAV clients do HTTP Basic, not OIDC — auth is htpasswd (bcrypt) or Baikal's
  own users. Do not spend time trying to put an outpost in front of it.
- **Clients:** DAVx5 on Android, Thunderbird, native iOS/macOS.
- **Backup:** the data is a handful of `.ics`/`.vcf` files under `apps` — small, but it needs its own
  mount row and a place in the backup set, since no Postgres dump label will catch it.

**Recommendation: Radicale**, unless you want a browser UI for adding accounts, in which case
Baikal.

## 5. Raspberry Pi — secondary DNS

Today AdGuard on the NAS is the only resolver on the LAN ([network.md](network.md) → `:53`): NAS off,
DNS off. The hardware requirements are settled: **Pi 4 or 5**, **64-bit arm64 OS (mandatory** —
there is no armv7 Komodo periphery image), **USB SSD not an SD card** (AdGuard writes query logs
continuously), on the tailnet. It becomes Komodo host 5 (`adguard-secondary`); Komodo has no node
cap, so nothing about the control plane blocks it.

The two open questions are both blockers, and both are design work rather than shopping:

1. **AdGuard's config is UI state** — the last big click-ops config on the estate. A
   secondary whose rewrites, filters and client rules drift from the primary is *worse* than no
   secondary, because it answers wrongly instead of not answering. Options: a sync tool between the
   two instances, committing `AdGuardHome.yaml` to this repo and accepting that the UI rewrites it
   (the same trap Authentik's blueprints solved), or manual export/import plus a probe that diffs
   the two. Unanswered.
2. **Failover shape.** Two DNS servers in FritzBox DHCP is the zero-machinery option; a keepalived
   VIP is real failover with more moving parts. **Start with two DHCP entries:** the outage this
   protects against is "the NAS is off", where the primary does not answer at all — the case clients
   handle correctly. A *responding but wrong* primary is the case DHCP does not save you from, and
   that is question 1's job, not keepalived's.

**Docs when it lands:** the host in `network.md` (second `:53`, tailnet IP), `docs/services/adguard-secondary.md`,
a `[[stack]]` entry plus `komodo/owned-stacks`, and the sync story in `adguard.md`.

## 6. UPS

[hardware.md](hardware.md) has it as a candidate; the estate's only answer to mains loss today is
"ZFS plus the nightly offsite backup", and
[host-reboot-power-loss.md](runbooks/incident-response/host-reboot-power-loss.md) documents the
unclean path.

**The goal is a clean shutdown, not ride-through.** Sizing follows from that: measure the build at
the wall first (N100 plus two HDDs and an NVMe is a small load), then pick a **line-interactive
600–900 VA** unit whose runtime at that draw comfortably exceeds the time it takes to stop ~55
containers and export the pools.

Non-negotiable: **USB (HID) or SNMP to the host.** A UPS with no data link protects the hardware and
not the pool. TrueNAS SCALE has a built-in UPS service (NUT) — driver `usbhid-ups`, this host as
master.

Decisions to record when it is bought:

- **The shutdown trigger.** A timer (for example: on battery for 5 minutes) or a battery percentage
  — deliberately *not* "low battery", because stopping every stack and exporting the pools needs
  headroom.
- **What else goes on the UPS.** FritzBox and switch too, if the point is to stay *reachable* during
  a short cut; NAS only, if the point is just to survive it. With NAS-only, a cut looks like an
  outage from outside either way and the external watchdogs
  ([external-heartbeat](runbooks/setup-operations/external-heartbeat.md), A1 Kuma) will say so.
- **Then the exporter.** `NUT exporter` is already on the [service-ideas](service-ideas.md) list:
  battery, load and runtime into the existing Grafana, plus an alert on "on battery" — the one signal
  that a short cut even happened.

**Docs when it lands:** `hardware.md` → Power protection, the unplanned-power-loss section of the
reboot runbook, and the new exporter in [observability.md](services/observability.md).

## 7. Staging for the deploy workflows

**What exists already**, so staging is not asked to re-do it: `compose-validate` + `docs-drift` on
every PR, the Renovate review gate ([renovate-pr-review](runbooks/setup-operations/renovate-pr-review.md)),
and on merge `deploy-stacks` — health gate plus auto-rollback
([deploy-stacks](runbooks/setup-operations/deploy-stacks.md)) — with the
[deploy-state probe](runbooks/setup-operations/deploy-state-probe.md) and the
[edge-access-policy probe](runbooks/setup-operations/edge-access-policy-probe.md) asserting the result.

**What none of that catches — the actual case for staging:**

- A stack that is *valid* but **will not start**: bad image entrypoint, a missing Komodo Variable, a
  healthcheck that never goes green. Today that is discovered by production going down and rolling
  back.
- **Auto-rollback only restores the folder this push changed**, and only twice per stack per seven
  days ([deploy-stacks → Health and rollback](runbooks/setup-operations/deploy-stacks.md#health-and-rollback)).
  It cannot undo a host path or a migrated database.
- **Migrations have nowhere to rehearse**: a Postgres major
  ([postgres-major-upgrade](runbooks/setup-operations/postgres-major-upgrade.md)), an Authentik jump,
  an Immich schema change.

**Shapes, cheapest first**

| | What it is | Catches | Cost |
| - | ---------- | ------- | ---- |
| **a** | **Ephemeral smoke test in CI.** On the runner VM, `docker compose up` the changed stack with dummy env and no host mounts, wait for healthy, `down -v` | Won't-start, missing env, broken healthcheck | A workflow change, no new host. The runner VM is 2 cores / 2 GiB ([runner-vm](runbooks/setup-operations/runner-vm.md)) — fine for one small stack, not for immich |
| **b** | **A staging Komodo Server**: second Server, `staging-*` Stacks, deployed from a branch | Everything in (a) plus the real Komodo path: Variables, ResourceSync, the health gate itself | A second set of Variables, its own proxy/DNS story, and `owned-stacks` / `reconcile-owned` gain a second dimension |
| **c** | **A dedicated staging host** (A1 has the headroom; a Pi does not) | Migrations and data-shaped failures | A fourth thing to patch and monitor |
| **d** | Blue/green per stack on the NAS | — | Not on 32 GB with the ARC. No |

**Recommendation: (a) now, (b) only for the stacks where a bad deploy actually hurts** — `caddy`,
`authentik`, `immich`, anything mid-migration. (a) is most of the value for a day of work; (b) is
where the effort goes if (a) turns out to pass things that still break.

**Constraints on whatever gets built**

- **No real secrets.** Staging Variables are dummies; the age vault stays out of CI.
- **No `data` access and no public name.** A staging stack that can write the mirror is a second
  production.
- **Test the real file.** Same `docker-compose.yml`, different Variables — not a parallel
  `staging/` copy that drifts from what actually deploys.

**Open decisions:** which host runs it, which stacks are in scope, and what triggers it (a `staging`
branch, or a PR label).

## 8. Host and container metrics to alert on

**What landed.** `vmalert` now runs beside VictoriaMetrics with four rules and mails through the
host ([observability.md → Alerting](services/observability.md#alerting)). That covers the metrics
the stack actually collects.

**What is missing is the data, not the alerting.** VictoriaMetrics scrapes *applications*: there is
no `node_exporter`, no container-level exporter and no SMART exporter, so four of the five signals
the alerting was meant for have no series at all —

- a dataset filling up (per-dataset, not just the two stores' filesystem);
- a container in a restart loop (it is `running` whenever a probe looks);
- memory pressure / OOM kills on the 32 GB box;
- NVMe wear and temperature (the `apps` pool has no redundancy).

**Two ways to get them, and they are not the same amount of work.**

- **Beszel already has all four.** Its agents run on every host and its database holds host,
  container, ZFS pool and SMART history — every stack's memory limit was sized from it. It has
  its own alert rules, so this is a configuration job, not a new stack. The catch is delivery:
  Beszel notifies over SMTP or shoutrrr, and this estate has no SMTP credential
  ([email-setup.md](runbooks/setup-operations/email-setup.md)), so a webhook sink has to exist
  before its alerts can reach anyone.
- **Exporters into VictoriaMetrics** (`node_exporter` on four hosts, a container exporter,
  `smartctl_exporter`) put the data where the rules, the dashboards and the 1-year retention already
  are, at the cost of four more containers, four scrape targets and four rows in
  [network.md](network.md).

**Decide which before building either.** Two alerting systems with overlapping rules is the outcome
to avoid.

## 9. HDD expansion — a `media` pool

**Why.** `data` (2× 4 TB mirror, ~3.5 TB usable) holds 2.28 TB, and 2.02 TB of that is
`data/mediaserver` ([storage.md](storage.md)). The media library is what grows. It isn't urgent at
~65%; the goal is to buy before `data` reaches 80%, when ZFS starts slowing down, not after.

**Decided**

- **Keep the 4 TB mirror.** It stays as `data` and holds the important data only: `immich`,
  `paperless`, `smb_share`.
- **A second SATA card first.** An **ASM1166** (6 ports, PCIe gen3 x2) goes in the long slot and
  the existing ASM1064 moves to the x1 slot: 2 + 6 + 4 = **12 SATA ports** for 8 bays.
- **New pool `media`: 4× 12–16 TB as RAIDZ2.** Survives any two disk failures; ~32 TB usable
  with 16 TB disks, ~15× today's media.
- **`mediaserver` and `romm` move to `media`**; the 500 GB `romm` quota goes up.
- **`media` holds local replicas of `data` and `apps`**, so the important data and every database
  have a second copy on the NAS as well as the Hetzner one. The `apps` replica doesn't replace an
  NVMe mirror, but it turns a restore from "pull from Hetzner" into a local `zfs send`.

**Shape**

```text
data  (2× 4 TB mirror)          immich, paperless, smb_share       -> Hetzner nightly (unchanged)
media (4× 12–16 TB RAIDZ2)      mediaserver, romm
                                backup/data/*  <- local ZFS replication from data
                                backup/apps/*  <- local ZFS replication from apps
apps  (NVMe, + SATA SSD mirror?)                                   -> optional, see below
```

**Why a separate pool and not a second vdev in `data`.** ZFS spreads new writes across all vdevs,
so every dataset, the important ones included, would depend on every disk, and pulling a vdev back
out later is messy. A separate pool keeps the failure domains apart: losing `media` costs
re-downloadable media plus a *copy*, never the only local copy of the photos. That's also what
makes the local replica worth having.

**Why RAIDZ2 over the alternatives considered**

| Layout | Usable (16 TB) | Survives | Why not |
| ------ | -------------- | -------- | ------- |
| 2× mirror | ~16 TB | 1 disk | Fine today, but growing means replacing both disks or retiring `data` |
| 3× RAIDZ1 | ~32 TB | 1 disk | A rebuild reads every other disk for days with no redundancy left; widening it later makes that worse. RAIDZ1 can't become RAIDZ2 |
| **4× RAIDZ2** | **~32 TB** | **any 2** | Chosen: same space as RAIDZ1-of-3, still protected during a rebuild. Only possible with the second card |
| USB DAS | — | — | USB bridges drop disks and hide SMART; TrueNAS advises against USB pool disks. Bays aren't the limit anyway |

A DAS stays the path for when all six 3.5" bays are full: a SAS HBA in the x2 slot to a JBOD
enclosure (~2 GB/s, plenty for HDDs), at the cost of ~10 W and the N100's deep idle states.

**Hardware**

- **Slots:** ASRock N100M, a long PCIe 3.0 slot wired **x2** and a PCIe 3.0 **x1** slot.
  Confirm the x2 wiring in the manual before buying.
- **ASM1166 firmware:** many cards ship with firmware that blocks ASPM (the N100 then idles
  higher) and exposes 32 phantom ports (slow boot). Flash the updated firmware before use.
- **Bays:** Jonsbo N4, six 3.5" (**4 hot-swap** on the backplane, 2 fixed) and two 2.5". After:
  all six 3.5" used, one 2.5" free.
- **Where the disks go:** the four `media` disks in the **four hot-swap bays**. That pool has the
  most disks, so the most replacements over its life, and a hot-swap bay makes each one a
  front-panel job. The 4 TB pair goes in the two fixed bays; if it sits in hot-swap bays today, move
  it with the host off (ZFS finds disks by GUID, not by bay or port). Label each bay with its
  disk's serial.
- **Which port:** spread the four `media` disks across both cards, so neither the x1 link
  (~985 MB/s) nor one card's failure takes out more than two RAIDZ2 members.
- **Hot-swap needs hotplug on the port.** Enable it per SATA port in the BIOS for the onboard ports
  (the ASM cards do AHCI hotplug on their own). Even then: `zpool offline` the disk before pulling
  it, and check the pool is otherwise healthy.
- **PSU / cooling:** 650 W is plenty, but six HDDs spin up at once: check it boots cleanly. Large
  NAS or recertified enterprise disks are louder and run hotter than the 4 TB ones, so check drive
  temperatures after a week ([hardware.md](hardware.md) → Cooling).
- **RAM:** 32 GB is enough ARC for this.

**Migration outline** (turns into a runbook before it is done)

1. **Fit the ASM1166**, flash it, move the ASM1064 to the x1 slot. Check both pools import and
   every disk shows up with SMART, before any new disk goes in.
2. **Burn in** all four disks: SMART long, then a full `badblocks -wsv` pass (days at this size),
   then SMART long again. Recertified drives: check the warranty and power-on hours first.
3. **Create `media`** in the TrueNAS UI as RAIDZ2, `ashift=12`, `lz4`, `recordsize=1M` on the
   media datasets.
4. **Move `data/mediaserver`** with `zfs send -R` / `recv` into `media/mediaserver`, **as one
   dataset**. Downloads and library must stay on the same filesystem, otherwise the *arr imports
   stop being hardlinks and become copies ([arr.md](services/arr.md), [architecture.md](architecture.md)).
   Do an incremental final send with the media stacks stopped, then switch over. Same for
   `data/romm` → `media/romm`.
5. **Repoint the bind mounts** from `/mnt/data/mediaserver` → `/mnt/media/mediaserver` in `arr`,
   `downloads`, `jellyfin`, `books`, `games` and `scripts/kiwix-seed.sh`, and `/mnt/data/romm` →
   `/mnt/media/romm` in `romm`; raise the `romm` quota. Update the `storage.md` mount table in the
   same commit: `docs-drift` checks it.
6. **Destroy the old datasets** on `data` only after a week on the new pool.
7. **Local replication:** TrueNAS replication tasks `data/immich`, `data/paperless`,
   `data/smb_share` → `media/backup/data/…` and `apps` (recursive, minus the TrueNAS-internal
   datasets) → `media/backup/apps/…`, daily, with their own retention. Today there are none
   ([scheduled-tasks.md](scheduled-tasks.md)).

**Optional, same card:** a SATA SSD in the free 2.5" bay, attached as a mirror to the `apps` NVMe.
ZFS mirrors across NVMe and SATA fine (writes at the slower disk's speed). That gives `apps`
redundancy without a second M.2 slot — see the NVMe-mirror row below.

**Still open**

- **12 vs 16 TB, and NAS vs recertified enterprise.** Decide on price per TB when buying.
  Recertified is the cheap route, but check noise if the case sits in a living space.
- **The new `romm` quota.**

Not backed up off-site, deliberately: the media itself (re-downloadable, as today). The replicas of
`data` and `apps` are on Hetzner from their source pools already, so exclude `media/backup` from any
future cloud-sync task so it isn't pushed twice.

**Docs when it lands:** [storage.md](storage.md) (disks, pools, datasets, mount table, a scrub and
SMART row for `media`, scrub on a day other than Monday), [hardware.md](hardware.md) → Storage
controllers, [scheduled-tasks.md](scheduled-tasks.md) (replication tasks), the "NOT backed up" table
in [backup.md](runbooks/backup-restore/backup.md) (dataset paths),
[disk-failure-replacement.md](runbooks/incident-response/disk-failure-replacement.md) (a RAIDZ2 pool),
and the service docs of every stack from step 5.

## 10. Dawarich — a self-hosted location timeline

**Why.** Google took Timeline off the web and moved location history onto the phone. Dawarich is the
replacement: it ingests your position over time, draws the map and the trips, and — the point — lets
you **import the Google Takeout location history** so the back-catalogue survives the move. It sits
next to the photos: [immich.md](services/immich.md) already holds the *where a photo was taken*, and
Dawarich can read Immich's API to place photos on the same timeline.

**Shape.** A four-part stack: Rails web + a Sidekiq worker + **Postgres with PostGIS** + Redis.
Live tracking comes from a phone app (the Dawarich app, or OwnTracks / Overland) posting points;
the one-time Takeout import backfills the history. Ruby, not JVM — the
[service-ideas](service-ideas.md) "skip JVM here" rule does not bite.

**Host: NAS.** It is private data that pairs with Immich, LAN/tailnet-only, and nothing about a
location timeline needs to keep working while the house is dark — so none of the A1's independence
argument applies. Rails + Sidekiq + Postgres + Redis lands under ~1.5 GB, inside the 3–4 GB NAS
budget; the point rows live in Postgres on the `apps` NVMe and grow slowly.

**The two things to decide before it is built**

1. **Reverse-geocoding — the real sizing question.** Turning coordinates into place names needs a
   geocoder. Self-hosting **Nominatim** is a planet-sized import and several GB of RAM: **do not put
   it on the N100.** Use Dawarich's hosted **Photon** endpoint (or point at a public Nominatim) and
   accept the one external dependency for that lookup — the coordinates themselves never leave the
   NAS, only the "what's near this point" query does. Note which, since it is the only thing here
   that talks to the internet.
2. **PostGIS in the dump path.** The `nas.backup.*` labels run `pg_dump`
   ([postgres-dump](runbooks/backup-restore/postgres-dump.md)), which captures the data fine — but a
   restore needs the **PostGIS extension present before the dump loads**, or it fails on the first
   geometry type. Dawarich ships its own PostGIS Postgres image, so the label just has to target
   that container; record the extension caveat in `postgres-dump.md` so a restore does not surprise
   anyone.

**Auth: its own accounts, not NAS Authentik.** Dawarich has built-in users; create the one account
and disable registration. LAN/tailnet-only behind a `lan_only` Caddy vhost anyway, so no public name
and no outpost — same as CalDAV (item 4).

**Docs when it lands:** new stack + `docs/services/dawarich.md`, the `lan_only` vhost (no new host
port — the web UI stays container-internal behind Caddy), any bind mount in
[storage.md](storage.md), the dump label plus the PostGIS caveat in `postgres-dump.md`, and a line
in `immich.md` if the photo integration is turned on.

---

## Already in the docs, still to do

Not new ideas — things the docs already admit are open. Kept here so they are in one list.

| Item | Where | Note |
| ---- | ----- | ---- |
| **Revoke the paperless-ai Gemini API key** | [paperless.md](services/paperless.md) | The sidecar is gone (it sent documents to Google); the key is still live in Google's console. Security, and it takes a minute |
| **Run a full restore drill** | [restore-drill.md](runbooks/backup-restore/restore-drill.md) | Step 1 is automated monthly now ([the automated drill](runbooks/backup-restore/restore-drill.md#the-automated-drill)), but steps 2–4 have never run and the Oct quarter is due — "a skipped quarter is a finding" |
| **AdGuard config out of the UI** | [adguard.md](services/adguard.md) | Rewrites, filters and client rules are UI state nothing reviews. The blocker for item 5 |
| **Sweep proxied apps for hard-coded trusted-proxy state** | — | Trusted-proxy / real-IP / allowed-host settings held in an app's own config, not in `stacks/`. Jellyfin's `KnownProxies` still pointed at the retired NPM subnet after the Caddy move, which silently broke its SSO redirect. No other app has been checked |
| **Decide on Cloudflare Tunnel** | [cloudflare-tunnel-cutover.md](runbooks/setup-operations/cloudflare-tunnel-cutover.md) | Designed, nothing built. Either schedule it or mark it *won't do* — a plan that is neither is just a stale file |
| **NPMplus leftovers on `crowdsec`** | `stacks/caddy/docker-compose.yml` | The `/mnt/apps/npm/crowdsec/*` config paths. Moving them is a data migration |
| **Migration leftovers on the NAS host** | [storage.md](storage.md) | Datasets `apps/npm` (NPMplus data; CrowdSec's two dirs still live inside it) and `apps/portainer`, their snapshots `apps/npm@pre-caddy-2026-09-06` and `apps/portainer@pre-removal-2026-09-17` (on `KEEP_SNAPSHOTS` in `nas-deterministic-checks.sh`), `/mnt/apps/filebrowser`, and `/mnt/apps/scripts/*.bak-20260917*`. Delete, or decide to keep, each. Also open and not re-checked since: Kuma monitors for "Portainer UI" and NPMplus's admin UI on `:81`, and the classic PAT behind the old `RENOVATE_TOKEN`, deleted from the repo but not revoked in GitHub |
| **`micro-vps-ingress` inline `configs:` → a real `nginx.conf`** | [micro-vps-ingress.md](services/micro-vps-ingress.md) | The inline block only existed because Portainer shipped compose content alone; Komodo clones the repo. `stop_grace_period` / `stop_signal: SIGTERM` on that nginx is also still unapplied: every recreate costs every public site ~11 s, because nginx's graceful `SIGQUIT` waits on long-lived streams until Docker's 10 s kill |
| **micro VPS hardening** | [AGENTS.md](../AGENTS.md) → *Known issues* | The Oracle security-list rule for tcp/2333. The host iptables side is done (2026-09-23). (No fail2ban there is an accepted risk, not a to-do) |
| **Reconsider the `apps` NVMe mirror** | [storage.md](storage.md) | Accepted risk, but every database is on one NVMe, and local snapshots live on that same disk. The board has no second M-key M.2 for an NVMe mirror, but once item 9's second SATA card is in, a SATA SSD in the free 2.5" bay can mirror it. Pairs with item 6 |
| **Nothing triggers the `komodo` Stack's deploy** | [komodo.md](services/komodo.md) → *Operations* | `komodo` is off `owned-stacks` by design, and no webhook points at Komodo, so a merged change to `stacks/komodo/` sits undeployed until somebody presses Deploy. On 2026-09-23 that meant Core and Mongo ran without the log cap for hours after every other stack had it, and nothing noticed. A `deploy-komodo` Procedure modelled on `deploy-runner` (hourly `DeployStackIfChanged`, its own cron slot) would close it — it must judge the result by the containers, since the record always reads `success=false` when Core recreates itself. The four peripheries cannot be automated this way and stay hand-deployed: a periphery executing its own recreate kills the process running the command |

