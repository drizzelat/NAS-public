# Runbook: Kiwix seeding

qBittorrent seeds the newest [Kiwix](https://kiwix.org/) ZIM files: offline Wikipedia and Project
Gutenberg, used where the web is censored, expensive or absent. Kiwix publishes every file as a
torrent whose web seeds are its own mirrors, so each peer here takes load off those mirrors. It runs
in the existing [`downloads`](../../services/downloads.md) stack. There is no new service, only a
category, a weekly script and working port forwarding.

## What is seeded

[`scripts/kiwix-seed.sh`](../../../scripts/kiwix-seed.sh) keeps the newest file of each flavour, in
this priority order, inside a **300 GB** budget:

| Flavour | Size (2026-09) | What it is |
| ------- | -------------- | ---------- |
| `wikipedia/wikipedia_en_all_maxi` | 119 GB | English Wikipedia with images |
| `wikipedia/wikipedia_de_all_maxi` | 49 GB | German Wikipedia with images |
| `wikipedia/wikipedia_en_all_nopic` | 49 GB | English Wikipedia, text only — what low-bandwidth users pick |
| `wikipedia/wikipedia_de_all_nopic` | 14 GB | German Wikipedia, text only |
| `gutenberg/gutenberg_de_all` | 10 GB | Project Gutenberg, German books |

That is about 241 GB in `/mnt/data/mediaserver/data/torrents/kiwix` (`/data/torrents/kiwix` inside
qBittorrent), category `kiwix`, which leaves about 59 GB of the budget for the files to grow. The `data`
pool had 1.23 T free on 2026-09-11.

## 1. Make port forwarding work

Without a forwarded port, only peers that accept incoming connections can trade with qBittorrent,
and most do not. Forwarding has worked since 2026-09-14. Before that the WireGuard key had been
generated without NAT-PMP: on every reconnect gluetun logged
`connection refused - make sure you have +pmp at the end of your OpenVPN username`, and qBittorrent
sat on its default port `6881`.

Proton answers NAT-PMP only on its P2P servers, and only for a WireGuard key generated with NAT-PMP on.
The compose sets `PORT_FORWARD_ONLY=on`. To replace the key (done 2026-09-14; repeat for a rotation):

1. [account.protonvpn.com](https://account.protonvpn.com/) → **Downloads** → **WireGuard
   configuration**: platform *GNU/Linux* (or *Router*), **NAT-PMP (Port Forwarding)** on, any P2P
   server (gluetun picks its own). Create it and copy the `PrivateKey` value.
2. `scripts/secrets.sh edit downloads` → replace `WG_KEY`.
3. `scripts/secrets.sh push downloads` redeploys the stack with the new key.
4. Verify on the NAS:

   ```sh
   sudo docker logs gluetun 2>&1 | grep -i 'port forward' | tail -3
   sudo docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/portforward      # "port" is non-zero
   sudo docker exec gluetun wget -qO- http://127.0.0.1:8082/api/v2/app/preferences | jq .listen_port   # the same port
   ```

5. Revoke the old WireGuard configuration in the Proton dashboard.

## 2. Install the cron

Installed 2026-09-14 as cron id 19. To recreate it: TrueNAS → System → Advanced → Cron Jobs, or from the shell:

```sh
sudo midclt call cronjob.create '{"description":"Kiwix seeding","command":"/bin/sh /mnt/apps/scripts/nas/scripts/kiwix-seed.sh",
  "user":"root","schedule":{"minute":"45","hour":"4","dom":"*","month":"*","dow":"3"},
  "enabled":true,"stdout":true,"stderr":true}'
```

The schedule is Wednesday 04:45, clear of the nightly backup window and the Renovate and merge crons. Kiwix publishes
new files about monthly, so weekly is plenty. The script runs straight out of the auto-pulled repo
clone ([nas-repo-autopull](nas-repo-autopull.md)).

Run it once by hand to start the downloads:

```sh
sudo /bin/sh /mnt/apps/scripts/nas/scripts/kiwix-seed.sh
sudo tail /var/log/kiwix-seed.log
```

## How the script decides

- **Newest per flavour**, from the mirror's directory listing (`https://download.kiwix.org/zim/<directory>/`).
  Sizes are rounded up to whole GB and counted in priority order. A flavour that would take the total
  past the budget is skipped and logged.
- **Adds** a missing file's `.torrent` with category `kiwix` and **per-torrent share limits of -1 (none)**.
  That matters because the global `ShareLimitAction` is *remove with content*, set for the \*arr downloads;
  without the override, any global ratio limit would delete these too.
- **Removes** torrents in `kiwix` that nothing wants any more (superseded months, dropped flavours),
  **with their files**, but only once every wanted torrent is present and complete. Every flavour keeps
  a seeded copy the whole time, so disk use peaks at old + new while a new month downloads.
- **If it cannot read a listing** (mirror down, format changed), it keeps whatever that flavour is seeding,
  logs a `WARN` and mails it (see [Alerts](#alerts)).
- **The `kiwix` category belongs to the script.** Anything else placed there is removed on the next run.

## Watching it

Grafana → *NAS (git)* → **Community services** (`community-services`), section *Kiwix seeding*: upload
(Kiwix against all of qBittorrent), connected peers, whether the forwarded port lets peers in
(*Incoming port*), and a table per file with progress, peers, upload and ratio. It reads the
`qbittorrent-exporter` in the `downloads` stack and picks Kiwix torrents by the `.zim` in their name,
not by category: the exporter labels torrents by name only.

### Alerts

The script mails the TrueNAS *From* address through `mail.send` (the same path as the dump and
cloud-sync jobs), at most once per run:

| Subject | When | What it means |
| ------- | ---- | ------------- |
| `[NAS] Kiwix seeding: a flavour could not update` | A mirror listing had no `<flavour>_YYYY-MM.zim`, or a new file's `.torrent` did not resolve | Those flavours keep seeding the file they already have. One mail after a mirror outage is noise; the same mail two Wednesdays running means the listing format or a flavour name changed, so fix the `sed` pattern in `newest()` or the `FLAVOURS` entry |
| `[NAS] Kiwix seeding ABORTED` | The qBittorrent Web API was unreachable, or any command stopped the run under `set -e` | Nothing after that point was added or pruned. The log shows how far it got |

Not mailed: `skip: qbittorrent is not running` (container state is covered by the health check and the
deploy-state probe), a download that stays incomplete and holds back pruning (the dashboard's table
shows it), and the cron not firing at all.

## Changing what is seeded

Edit the `FLAVOURS` default (or `BUDGET_GB`) in the script and push; the clone picks it up within
15 minutes. Or override it in the cron command, e.g.
`KIWIX_SEED_BUDGET_GB=400 /bin/sh /mnt/apps/scripts/nas/scripts/kiwix-seed.sh`. A flavour is its
directory on the mirror plus the file name before `_YYYY-MM.zim`.

**To stop seeding**, run it once with an empty list, which removes every `kiwix` torrent and its
files, then delete the cron job:

```sh
sudo env KIWIX_SEED_FLAVOURS= /bin/sh /mnt/apps/scripts/nas/scripts/kiwix-seed.sh
```

## Other community torrents

For [Academic Torrents](https://academictorrents.com/) datasets or Linux ISOs, add them in the
qBittorrent UI under a category of their own (e.g. `community`, save path `/data/torrents/community`)
and set each torrent's share limits to *no limit*, for the same reason as above. The script never
touches other categories. Datasets with few seeders help more than popular ISOs.

## Gotchas

- **No quota.** `data/mediaserver` has none, so the budget is the only bound.
- **Not backed up.** `data/mediaserver` stays out of the offsite chain on purpose; a lost file downloads again.
- **Uploads go out over the home line** (through Proton), which remote Jellyfin/Immich, Snowflake and Conduit
  also use. qBittorrent's global upload rate is unlimited; set a limit in *Options → Speed* if streaming suffers.
- **The \*arr apps ignore this category.** They only import from their own.
