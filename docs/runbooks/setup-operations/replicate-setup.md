# Runbook: Replicate this setup from scratch

This guide builds a NAS like the one this repo documents: a **TrueNAS** host running
all services as **Docker Compose stacks that Komodo deploys from git**, fronted by **Caddy**,
exposed to the internet through **Cloudflare and a cheap VPS that forwards `:80/:443` to Caddy over
Tailscale** (no public IP needed at home), gated by **Authentik SSO** and a **per-vhost client-IP
rule**, with **AdGuard** as the LAN DNS resolver and **nightly encrypted backups to a Hetzner
Storage Box**.

You do not need identical hardware or the same domain. Substitute your own values for
every `example.com`, `192.168.178.x`, dataset path, and credential.

> This is the big-picture build order. Each phase links to the focused runbook that
> covers it in detail. Read those before executing the phase.

## What you are building (architecture at a glance)

```text
            Internet
               │  :80/:443  (via Cloudflare for every name except the video one)
        ┌──────▼────────┐
        │  VPS (cheap)  │  nginx stream proxy, public IP
        │  SNI allowlist│
        └──────┬────────┘
               │  Tailscale (WireGuard) — :443 → NAS :8443 with a PROXY-protocol header
        ┌──────▼───────────────────────────────────────┐
        │  NAS (TrueNAS, no public IP)                  │
        │                                               │
        │  Tailscale (subnet router) → Caddy (edge)     │
        │     ├─ one Caddyfile in git: vhosts + @lan    │
        │     ├─ CrowdSec (bouncer + AppSec)            │
        │     └─ Authentik SSO (apps use native OIDC)   │
        │                                               │
        │  Komodo ◄── DeployStack from GitHub Actions   │
        │     └─ all service stacks (this repo)         │
        │                                               │
        │  AdGuard = LAN DNS    ZFS pools: apps + data  │
        │  nightly Cloud Sync → Hetzner Storage Box     │
        └───────────────────────────────────────────────┘
```

Key design choices to copy:

- **No port-forwarding at home.** The home NAS keeps no public IP. A small VPS holds the
  public IP; its nginx stream-forwards public `:80/:443` to the NAS **over Tailscale**
  (the NAS runs a Tailscale node). Your router/ISP never needs an inbound hole.
- **Hub-and-spoke Docker networks.** Caddy is the only container on every `proxy_<stack>`
  network; each app sits on its own `proxy_<stack>` network and exposes **no host port**. Traffic
  can only reach an app via Caddy. See [network.md](../../network.md).
- **Exposure is deny-by-default, twice.** The VPS forwards only an SNI allowlist of public names
  (the Cloudflare-proxied ones only from Cloudflare); on the NAS every other vhost imports a
  `lan_only` snippet that admits LAN + tailnet and aborts everything else. A scheduled probe
  asserts both layers ([edge-access-policy-probe](edge-access-policy-probe.md)).
- **Git, not click-ops.** Stacks, the edge policy (the Caddyfile) and Authentik's providers
  (blueprints) live in this repo. A push redeploys only the stack whose folder changed.
- **Secrets in an encrypted vault.** Stack env and SSH keys are age-encrypted in `secrets.enc/`
  and unlocked with one passphrase ([secret-sync](secret-sync.md)).

## Phase 0 — Prerequisites

| You need | Notes |
| --- | --- |
| A machine for TrueNAS | Bare metal or VM. Mirror disks for data, single SSD for apps is acceptable if backed up offsite (see [storage.md](../../storage.md)). |
| A domain on Cloudflare DNS | Caddy's wildcard certificate uses the Cloudflare DNS-01 challenge, and Cloudflare proxies the public names. This repo uses `example.com`. |
| A small VPS with a public IP | For the nginx ingress + Tailscale node. A 1-vCPU instance is plenty (this setup uses an Oracle free-tier VPS). |
| A Hetzner Storage Box (or any SFTP target) | For offsite backups. |
| A git host for this repo | A private GitHub repo here — the deploy, review and health-check automation is GitHub Actions. |
| A workstation | To edit compose files, run `scripts/secrets.sh`, and push. |

## Phase 1 — Install TrueNAS and build the pools

1. Install **TrueNAS** (SCALE) on the host. Boot device separate from data disks.
2. Create the **ZFS pools** matching your disks. This setup uses two:
   - `apps` — fast SSD/NVMe, single disk (accepted risk, covered by snapshots +
     offsite backup), mounted `/mnt/apps`. Holds every service's config/database.
   - `data` — mirrored HDDs, mounted `/mnt/data`. Holds bulk user data (media,
     photos, documents, SMB shares).
3. Create **datasets** per service so each can be snapshotted/backed up independently — and make
   each service's state a **leaf** dataset, because the offsite chain syncs leaves only. See the
   dataset table in [storage.md](../../storage.md) for the layout to mirror.
4. Set up **disk health tasks** (ZFS scrub + SMART) under Data Protection — schedule
   table in [storage.md](../../storage.md). TrueNAS's SMART tasks skip NVMe; this setup adds
   [`nvme-smart-test.sh`](../../../scripts/nvme-smart-test.sh) ([scheduled-tasks.md](../../scheduled-tasks.md)).
5. Enable **SSH** and add your public key to the admin user (Credentials → Users →
   Edit → SSH Public Keys). You will manage backup tasks over SSH with `midclt`.

> Helper: [`scripts/convert_datasets.sh`](../../../scripts/convert_datasets.sh)
> converts an existing directory into its own dataset (e.g. splitting mediaserver
> config into per-app datasets).

## Phase 2 — Komodo, the vault, the runner and the host clone

Komodo Core is the control plane: a `komodo` stack (Core + MongoDB) that deploys itself once
bootstrapped, plus one **periphery** per host that Core deploys through. Until 2026-09-17 this
estate used Portainer here; [archive/portainer.md](../../archive/portainer.md) has that history.

1. Fork/clone **this repo** to your own git host and edit it to your values (domain, paths, IPs) as
   you go.
2. Create the **secret vault** — `scripts/secrets.sh init` — and keep the passphrase in your
   password manager ([secret-sync](secret-sync.md)).
3. **Bootstrap Komodo** by hand, once: the `apps/komodo` dataset, the Core stack with its vault env,
   then the NAS periphery — [komodo.md](../../services/komodo.md) → Bootstrap and
   [nas-periphery.md](../../services/nas-periphery.md). Core has no host port: until Caddy exists
   (Phase 3), drive it through its API from the NAS, or with a temporary port mapping.
4. **Declare the estate:** create the git account and the ResourceSync `komodo-resources` over
   [`komodo/resources.toml`](../../../komodo/resources.toml), read its pending diff, execute it. Then
   `scripts/secrets.sh komodo-vars --all` writes every Stack's Variables from the vault.
5. Create the Komodo service user `deploy-stacks` and set the repo's Actions secrets
   `KOMODO_DEPLOY_API_KEY`/`_SECRET` and `ROLLBACK_TOKEN` ([komodo.md](../../services/komodo.md) →
   Credential). Build the [runner VM](runner-vm.md) and bring the **self-hosted runner** up with
   the `deploy-runner` Procedure — CI never deploys the runner it runs on
   ([github-runner.md](../../services/github-runner.md)).
6. From here on a push is the deploy: [`deploy-stacks`](../../../.github/workflows/deploy-stacks.yml)
   creates new Stacks and deploys changed ones ([deploy-stacks.md](deploy-stacks.md)).
7. Clone the repo onto the NAS at `/mnt/apps/scripts/nas` with its auto-pull cron: every host cron
   runs from it ([nas-repo-autopull](nas-repo-autopull.md)). Container config (the Caddyfile,
   blueprints, observability) comes from Komodo's own clone instead.

## Phase 3 — Networking core: Caddy + CrowdSec (+ VPS ingress over Tailscale)

This is the stack that makes everything reachable. Deploy it before the apps.

> **Bootstrap access (chicken-and-egg).** Phases 3–5 set up the very machinery that makes
> `*.example.com` resolve and route — so you cannot use those hostnames to configure them.
> While bootstrapping, reach the infrastructure UIs by **host IP and port directly**:
>
> | UI | Bootstrap URL | After setup |
> | --- | --- | --- |
> | AdGuard | `http://192.168.178.111:30004` *(temporary mapping — see below)* | `https://adguard.example.com` |
>
> No service keeps a permanent UI host port — every app behind Caddy has none (hub and spoke), Caddy
> itself has no UI to reach, and Komodo is driven by its API from the NAS until Caddy is up. **AdGuard publishes only
> `:53` (DNS)**, not its web UI; to reach the wizard during bootstrap, temporarily add
> `30004:30004` to the adguard stack, then remove it once Caddy
> proxies `adguard.example.com`. The chain is: AdGuard rewrites `*.example.com` → NAS IP
> (Phase 4) **and** Caddy has a vhost for the name plus the wildcard cert (this phase) before the
> friendly hostnames work on the LAN. The wildcard cert's **DNS-01 challenge works regardless** —
> it writes TXT records at Cloudflare, not on the NAS.

1. **NAS side:** the `caddy` stack ([caddy.md](../../services/caddy.md)) bundles **Caddy** (a
   custom build with the Cloudflare DNS and CrowdSec modules, publishing `:80/:443/:8443`) and
   **CrowdSec**, and defines every `proxy_*` network. Put `CLOUDFLARE_API_TOKEN` and
   `CROWDSEC_API_KEY` in its vault env and write its Variables with `scripts/secrets.sh komodo-vars caddy` and deploy it from Komodo. Caddy
   requests the **wildcard TLS cert** itself on first start (DNS-01) and renews it on its own. The
   whole edge policy is [`stacks/caddy/Caddyfile`](../../../stacks/caddy/Caddyfile).
2. **CrowdSec:** register the bouncer key and point the acquisition at Caddy's access log —
   [crowdsec-bouncer.md](crowdsec-bouncer.md) → The Caddy bouncer.
3. **VPS side:** join the VPS to your tailnet (`tailscale up --accept-routes`), apply its periphery and add it as
   a Komodo Server ([a1-provision.md](a1-provision.md) Phase 5 has the shape), and deploy the `micro-vps-ingress` stack — **nginx** in `stream` mode on
   the public `:80/:443`, forwarding `:80` to the NAS tailnet IP `:80`, and `:443` through an SNI
   allowlist, with a PROXY-protocol header, to Caddy's `:8443`. Raw TCP; no TLS on the VPS. Full
   detail: [vps-tailscale-backhaul](vps-tailscale-backhaul.md) and
   [micro-vps-ingress.md](../../services/micro-vps-ingress.md). *(Requires the NAS Tailscale node
   from Phase 8 — bring that up first.)*
4. **DNS at Cloudflare:** a proxied (orange) wildcard `*.example.com` pointing at the VPS public
   IP, and DNS-only (gray) records for anything that streams video or must bypass Cloudflare (here
   `jellyfin`; the Matrix names point at their own host).
5. Understand the **hub-and-spoke** wiring before adding apps: Caddy joins every `proxy_<stack>`
   network; each app joins only its own. The exact edit needed per new stack is in
   [network.md](../../network.md) → "Adding a New Stack".

## Phase 4 — LAN DNS (AdGuard)

Deploy the **adguard** stack ([adguard.md](../../services/adguard.md)) on `:53`. Point
your router's DHCP DNS at the NAS so the whole LAN resolves through it (ad/tracker
blocking + local rewrites for `*.example.com` → NAS so internal traffic skips the
VPS round-trip).

## Phase 5 — SSO and access control (Authentik)

1. Deploy **authentik** ([authentik.md](../../services/authentik.md)) — server, worker and Postgres.
   Put `AUTHENTIK_SECRET_KEY` and the DB password in its vault env. Providers and applications come
   from the blueprints in [`stacks/authentik/blueprints/`](../../../stacks/authentik/blueprints/);
   client secrets stay in the Authentik UI.
2. Keep the worker off the Docker socket ([authentik-socket-hardening.md](authentik-socket-hardening.md)).
3. For each service, decide its exposure (mirror the policy in
   [network.md](../../network.md) → "Access control"):
   - **LAN-only** (most): its vhost imports `lan_only`, and its name stays out of the VPS allowlist.
   - **Public, the app's own login via Authentik OIDC**: immich, mealie, files — Caddy proxies
     straight to the app, which runs the OIDC flow itself ([mealie-authentik-oidc](mealie-authentik-oidc.md),
     [filebrowser-to-quantum](filebrowser-to-quantum.md)). The app exposes no host port.
   - **Public with an SSO plugin and an edge login block**: Jellyfin, whose password endpoints
     Caddy answers with `403` on the public listener only ([jellyfin-authentik-sso](jellyfin-authentik-sso.md)).

## Phase 6 — Deploy the application stacks

Deploy the rest from the repo. See [services/](../../services/) for one doc per service. Roughly:

- **jellyfin**, **arr**, **downloads** (clients behind a Gluetun VPN tunnel —
  [downloads.md](../../services/downloads.md)), **books**, **games** — once a single `mediaserver`
  stack, now split so each gets its own review and rollback.
- **immich** — photos/videos with ML ([immich.md](../../services/immich.md)).
- **paperless** — document archive ([paperless.md](../../services/paperless.md)).
- **files**, **mealie**, **romm**, **homarr** (dashboard), **kuma** & **beszel** (monitoring),
  **observability** (traffic analytics).

For each: follow [new-service.md](new-service.md) — service doc, ports in
[network.md](../../network.md), bind mounts in [storage.md](../../storage.md), a vhost, and the
probe's host list.

## Phase 7 — Backups (do this before you trust the setup)

1. Create a **Hetzner Storage Box** (or any SFTP target) and an rclone Crypt
   password + salt. **Store both in your password manager** — without them the backup
   is unreadable.
2. Set up **TrueNAS Cloud Sync** as one snapshot-based, encrypted template task that
   [`scripts/cloudsync-chain.sh`](../../../scripts/cloudsync-chain.sh) drives across every leaf
   dataset at 03:00, pushing `/mnt/<pool>/<rel>` → `/backup/<pool>/<rel>`. Full design, schedule,
   and the `midclt` commands are in [backup.md](../backup-restore/backup.md).
3. Every database gets a nightly logical dump: put the `nas.backup.*` labels on the DB service and
   [`scripts/pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh) discovers it — see
   [postgres-dump.md](../backup-restore/postgres-dump.md). The dump directory must be inside a leaf
   dataset, or the chain will not carry it offsite.
4. Configure **local ZFS periodic snapshots** (fast first-line restore) per the table
   in [storage.md](../../storage.md).
5. Back up the **TrueNAS config itself** (holds all task definitions + the encryption
   key) — [truenas-config-backup.md](../backup-restore/truenas-config-backup.md).
6. Add the alarms that live outside the box: a [healthchecks.io](external-heartbeat.md) check per
   host, an off-site Kuma ([kuma-monitors](kuma-monitors.md)), and a quarterly
   [restore drill](../backup-restore/restore-drill.md).

## Phase 8 — Remote access (Tailscale)

Deploy the **tailscale** subnet-router stack on the NAS ([tailscale.md](../../services/tailscale.md))
advertising `192.168.178.0/24`. This is the **primary** remote-admin path for LAN-only services
**and** the backhaul the VPS ingress rides (Phase 3) — so in practice bring this up **before** the
DNS cutover in Phase 3. Keep the **router's built-in WireGuard VPN** as a **fallback**: it runs on
the router, so it still works when the NAS is offline (Wake-on-LAN). Details under "Remote
Administration" in [network.md](../../network.md).

## Verify the build

- [ ] A LAN-only service answers via `https://<svc>.<domain>` from inside the LAN and is refused
      from outside (Cloudflare `525`).
- [ ] `gh workflow run edge-access-policy.yml` comes back green.
- [ ] A public service (e.g. Immich) reaches its login from the internet.
- [ ] An OIDC app (e.g. Mealie) hands off to Authentik from the internet.
- [ ] Pushing a commit to one stack's folder redeploys **only** that stack.
- [ ] A Cloud Sync run completes and the encrypted files land in the Storage Box.
- [ ] A test PULL restore of one dataset succeeds with the Crypt password/salt.
- [ ] AdGuard is the LAN resolver and blocking works.

## Secrets you must generate (never commit in the clear)

Every stack's env lives encrypted in `secrets.enc/portainer-env/<stack>.env.age` and reaches
Komodo's Variables through `scripts/secrets.sh komodo-vars` / `push` ([secret-sync](secret-sync.md)); the variables each
stack needs are listed in its service doc. Outside the vault, in your password manager: the vault
passphrase, the rclone Crypt password + salt, the Hetzner login and the TrueNAS `pwenc_secret`
([truenas-config-backup](../backup-restore/truenas-config-backup.md)). The GitHub Actions secrets
live in the repo settings. See "What NOT to commit" in [AGENTS.md](../../../AGENTS.md).
