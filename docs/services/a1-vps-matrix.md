# Service: a1-vps-matrix (Matrix homeserver — Synapse)

## Overview

Self-hosted **Matrix** homeserver (Synapse) for high-availability messaging, deliberately run
**off the NAS** on its own dedicated Oracle Ampere A1 (`a1-matrix`, arm64) so chat keeps working
when the NAS is rebooting/resilvering/power-cut. Federated with the public Matrix network, login
via Authentik SSO (OIDC) with a break-glass local admin, and future-proofed for mautrix bridges.
Full build: [matrix-deploy runbook](../runbooks/setup-operations/matrix-deploy.md).

## Stack

- **Stack folder:** `stacks/a1-vps-matrix/`
- **Compose file:** `stacks/a1-vps-matrix/docker-compose.yml`
- **Deploy:** Komodo Stack `a1-vps-matrix` on Server `a1-vps`, adopted 2026-09-15
  ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its folder deploys it
  through Komodo.

## Access

| | |
|---|---|
| URL | `https://matrix.example.com` (client + federation); `example.com/.well-known/matrix/*` (discovery, Cloudflare-redirected to the A1); `https://element.example.com` (Element Web browser client); `https://<WEBTUNNEL_DOMAIN>` (a placeholder page whose secret path is the [WebTunnel bridge](a1-vps-webtunnel.md)); `http://pool.ntp.org` and its zone names (redirect for the [NTP Pool server](a1-vps-ntp.md#web-redirect)) |
| Port | Caddy `:80`/`:443` on the A1; Synapse `:8008` internal only. Federation delegated to `:443` — **8448 is not exposed**. |
| Auth | Authentik SSO (OIDC) only; break-glass local `@admin` (password login normally OFF) |

## Volumes / data

All **state** lives on the A1's 100 GB block volume at `/opt/matrix`. **Config is in git** as
inline compose `configs:` blocks with secrets interpolated from the stack env — the same pattern
`micro-vps-ingress` uses, and for the same reason: the Portainer Agent ships only compose content,
never sibling files ([GAP-2](../architecture-review-2026-08-20.md#gap-2--a1-matrix-host-has-no-backup)).

> ### A config target must never land inside a bind mount
>
> Synapse's configs mount at **`/config/…`**, not `/data/…`, even though Synapse's own directory
> is `/data`. This is not cosmetic. A first attempt on 2026-08-21 targeted `/data/homeserver.yaml`
> and `/data/appservices/*.yaml` — both inside the `/opt/matrix/synapse:/data` bind — and Docker
> materialised those configs **onto the host**, overwriting the real `homeserver.yaml` and both
> appservice registrations with `root:root` copies. Synapse crash-looped and Matrix was down about
> nine minutes.
>
> **Auto-rollback could not repair it.** Rollback reverts files in git; it has no reach into a host
> filesystem, so reverting the compose left the destroyed files exactly as they were. Recovery was
> manual, from copies taken beforehand.
>
> `SYNAPSE_CONFIG_DIR` deliberately stays `/data` (writable) while only `SYNAPSE_CONFIG_PATH` moves
> to `/config`, so anything the entrypoint writes still lands somewhere writable.
> `signing_key_path`, `media_store_path` and `pid_file` all stay under `/data`.

| Container path | Host path | Purpose |
|---|---|---|
| `/var/lib/postgresql` (postgres) | `/opt/matrix/postgres` | Postgres 18 data (synapse DB + one DB per bridge, `LC_COLLATE=C`) |
| `/data` (synapse) | `/opt/matrix/synapse` | **signing key**, media store, `homeserver.pid` — state only |
| `/config/…` (synapse) | *compose `configs:`* | `homeserver.yaml`, log config, both appservice registrations — in git |
| `/etc/caddy/Caddyfile` (caddy) | *compose `configs:`* | Caddy reverse-proxy + `.well-known` config — in git |
| `/data`, `/config` (caddy) | `/opt/matrix/caddy/{data,config}` | Let's Encrypt cert + Caddy state |
| `/app/config.json` (element) | *compose `configs:`* | Element Web client config — in git |
| `/data` (mautrix-whatsapp) | `/opt/matrix/bridges/whatsapp` | WhatsApp bridge (bridgev2) `config.yaml` + `registration.yaml` + crypto store |

## Environment variables

Komodo Variables `A1_VPS_MATRIX__*`, written from the vault (`secrets.enc/portainer-env/a1-vps-matrix.env.age`)
by `scripts/secrets.sh push a1-vps-matrix`, which then deploys through Komodo. Never commit secret values in the clear. Compose
interpolates every one of them into an inline `configs:` block at deploy time — Synapse itself
expands nothing — so a value missing from the Variables renders as an empty string (see Operations).

| Variable | Used in |
|---|---|
| `PG_PASS` | Postgres password for the `synapse` role, and `database.args.password` in `homeserver.yaml` |
| `REGISTRATION_SHARED_SECRET` | `homeserver.yaml` — account creation with `register_new_matrix_user` (break-glass admin) |
| `MACAROON_SECRET_KEY`, `FORM_SECRET` | `homeserver.yaml` — Synapse's own token and form signing |
| `OIDC_CLIENT_SECRET` | `homeserver.yaml` — the Authentik `matrix` provider |
| `WHATSAPP_AS_TOKEN`, `WHATSAPP_HS_TOKEN` | the mautrix-whatsapp appservice registration; must match the bridge's host-side `registration.yaml` |
| `DOUBLEPUPPET_AS_TOKEN`, `DOUBLEPUPPET_HS_TOKEN` | the shared double-puppet appservice registration |
| `WEBTUNNEL_DOMAIN`, `WEBTUNNEL_PATH` | the `Caddyfile`'s [WebTunnel](a1-vps-webtunnel.md) site: its address, and the secret path proxied to the bridge. Unset renders a harmless plain-HTTP placeholder site |

Still **host-side only** (not in git, not in Komodo): the signing key and the bridge's own
`config.yaml` + `registration.yaml` under `/opt/matrix/`.

## Dependencies

- **Postgres** (`matrix-postgres`, same stack) — Synapse's DB.
- **Caddy** (`matrix-caddy`, same stack) — TLS + reverse proxy.
- **Authentik** (`auth.example.com`, on the NAS) — SSO login. If the NAS is down, existing
  sessions/federation/bridges keep working; only new logins fail (use break-glass admin).
- **Cloudflare** — `matrix` + `element` A records (grey-cloud, DNS-only) + apex `.well-known/matrix/*` redirect.
- **mautrix-whatsapp** (`matrix-mautrix-whatsapp`, same stack) — WhatsApp bridge (bridgev2;
  version pinned in the compose file). Bot `@whatsappbot:example.com`; E2EE over appservice (MSC3202, needs
  `experimental_features` in `homeserver.yaml`). Own-account messages appear as `@stefan` via the
  shared `doublepuppet` appservice (`/opt/matrix/synapse/appservices/doublepuppet.yaml`). Config +
  registration host-side under `/opt/matrix/bridges/whatsapp/`; DB `mautrix_whatsapp`. Full build +
  gotchas: [matrix-deploy.md](../runbooks/setup-operations/matrix-deploy.md) Phase 6.
- **Element Web** (`matrix-element`, same stack) — optional browser client at `element.example.com`
  (Caddy `reverse_proxy element:80`). Config is the inline `element_config` block in the compose
  file. Native apps (Element X / Desktop) don't need it.
- **WebTunnel bridge** ([a1-vps-webtunnel](a1-vps-webtunnel.md), a stack of its own) — Caddy joins
  `proxy_a1-vps-webtunnel` and passes the bridge's secret path to `a1-webtunnel:15000`. The network is
  defined **here**, where the Caddy that needs it lives, and the bridge stack joins it as external, so
  this stack must deploy first.
- **Tailscale** — nightly backup transport to the NAS. Both databases and the media store are
  pulled by the NAS over the tailnet into `apps/a1-matrix`, which the 03:00 cloud-sync chain then
  carries offsite: [a1-matrix-backup runbook](../runbooks/backup-restore/a1-matrix-backup.md).

## Notes

- **Signing key is the crown jewel** — `/opt/matrix/synapse/example.com.signing.key`. Losing it
  permanently breaks the server's federation identity. In the age vault at
  `secrets.enc/ssh/example.com.signing.key.age`, plus stashed in Bitwarden.
- **Grey-cloud is deliberate** — federation and large media must reach the A1 without Cloudflare's
  edge (orange-cloud injects challenge pages that break S2S and caps uploads at 100 MB).
- **LAN split-horizon:** AdGuard rewrites `matrix.example.com` **and** `element.example.com`
  → `198.51.100.20` override the `*.example.com → NAS` wildcard. The bare apex `example.com` is
  **not** rewritten, so LAN clients resolve it publicly and get Cloudflare's `.well-known/matrix/*`
  redirect like everyone else (verified 2026-09-11 from a LAN client: `301` to
  `matrix.example.com`). See the runbook Phase 2 §4.

## Operations

> **Config changes are a git push now.** `homeserver.yaml`, the Synapse log config, both
> appservice registrations, the `Caddyfile` and Element's `config.json` are inline `configs:`
> blocks in `stacks/a1-vps-matrix/docker-compose.yml`. Edit, push, done.
>
> **Bump the `config-rev` label in the same commit.** A `configs.*.content` change alone does not
> reliably recreate the container, so without it your edit deploys and nothing restarts.
>
> **Get the env into Komodo before the compose lands.** `deploy-stacks` deploys on the compose
> push and renders `${VAR}` from whatever the Komodo Variables hold at that moment; if the new value is not
> there yet, every `${VAR}` renders empty — which is exactly how the 2026-08-21 outage started.
> Run `scripts/secrets.sh push a1-vps-matrix`, wait for `OK: a1-vps-matrix Variables written + deployed
> through Komodo`, then land the compose.
>
> **Secrets are `${VAR}`**, interpolated from the Komodo Variables at deploy time and held in
> the vault (`secrets/portainer-env/a1-vps-matrix.env`). Never paste a literal secret into the
> compose file.
>
> **Still host-side, deliberately:** the **signing key**, the media store, Caddy's cert/state
> dirs, and the WhatsApp bridge's own `config.yaml` + `registration.yaml`. The bridge rewrites its
> own config on version migrations, so a read-only `configs:` mount would break an upgrade — those
> two files stay editable on the host.
>
> SSH: `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20` (public IP, key-only;
> tailscale SSH is ACL-blocked). Host uses `sudo docker` (ubuntu not in the docker group).

### Restart / redeploy

Compose, image or config change → push to `stacks/a1-vps-matrix/` (runner fires the stack; bump
`config-rev` for a config change, see above), or **Deploy** on the Komodo Stack. Only the bridge's host-side `config.yaml` is still edited over SSH, followed by
`sudo docker restart matrix-mautrix-whatsapp`.

### Upgrade

Every image is pinned `tag@sha256:digest` (Renovate proposes bumps). Synapse: read its release
notes for schema migrations (auto-applied on start), bump the `image:` line, redeploy, watch
`sudo docker logs -f matrix-synapse` for "Synapse now listening on TCP port 8008". Rollback =
revert the commit + redeploy.

### Backup

Pulled by the NAS over the tailnet, both jobs running as root there — full procedure in the
[a1-matrix-backup runbook](../runbooks/backup-restore/a1-matrix-backup.md).

| What | When | Where it lands |
|---|---|---|
| `synapse` + `mautrix_whatsapp` DBs | 02:30, [`pg-dump-backup.sh`](../../scripts/pg-dump-backup.sh) | `/mnt/apps/a1-matrix/dumps` |
| Synapse media store (~9.3 GB) | 02:00, [`a1-file-backup.sh`](../../scripts/a1-file-backup.sh) | `/mnt/apps/a1-matrix/media_store` |
| Signing key | — | already in the vault, `secrets.enc/ssh/example.com.signing.key.age` |

The **WhatsApp bridge session lives in the `mautrix_whatsapp` database**, not on disk — that dump
is what saves you from re-pairing by QR. `/opt/matrix/bridges/whatsapp/` is ~593 MB of logs and is
deliberately not synced.

Dedicated keys do the pulling, each locked to one forced command on the A1 (`docker system
dial-stdio` for the dumps, `rrsync -ro` over the media store, and a third `rrsync -ro` key for the
[Kuma watchdog's](a1-vps-kuma.md) data); none can open a shell. Note that the Docker one is still
root-equivalent on the A1 — see the runbook's honest-limit note.

### Restore from backup

Stop the stack. Load the logical dumps into `matrix-postgres` and rsync the media store back —
[a1-matrix-backup runbook](../runbooks/backup-restore/a1-matrix-backup.md) → *Rebuilding the A1*.
The signing key must be restored from the vault or the federation identity is lost.

### Common failures

- **`docker pull` / lookups fail on the A1** — tailscale MagicDNS hijacked system DNS. Fix persists:
  `sudo tailscale set --accept-dns=false`.
- **Caddy can't get a cert** — port 80 must be open (both Oracle Security List and host iptables)
  and the `matrix` DNS record must be grey-cloud so Let's Encrypt HTTP-01 reaches the origin.
- **Bind-mounted path auto-created as a root-owned directory** — the host path (e.g.
  `/opt/matrix/bridges/whatsapp`) didn't exist before the stack deployed; create host directories
  **before** the stack folder lands on `main`. Configs are inline `configs:` now, so this only
  applies to state paths.

## Last updated

2026-09-17 — Caddy redirects the NTP Pool's names on port 80 to `https://www.ntppool.org/`
([a1-vps-ntp](a1-vps-ntp.md#web-redirect)); `config-rev` bumped.

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack; env goes into Komodo Variables before the compose lands.

2026-09-11 — Caddy also fronts the [WebTunnel bridge](a1-vps-webtunnel.md): a site block for
`WEBTUNNEL_DOMAIN`, and the `proxy_a1-vps-webtunnel` network, defined in this stack.

2026-09-11 — environment table completed (all nine variables the inline configs interpolate);
Element config, the LAN apex `.well-known` path and the backup script and key references brought
in line with the stack.

2026-08-21 — Phase 6 (WhatsApp bridge) live: `matrix-mautrix-whatsapp` (bridgev2 `v0.2606.0`) +
shared `doublepuppet` appservice; `mautrix_whatsapp` DB; E2EE over appservice (MSC3202,
`experimental_features` added to `homeserver.yaml`). WhatsApp QR link is the user step. History
import required **`backfill.enabled: true`** in the bridge config (ships `false` — the reason old
chats stayed empty; app-state/contacts sync regardless, which masked it) + a fresh device pair;
double puppeting confirmed (backfilled own messages attributed to `@stefan`). See runbook Phase 6.2
gotcha 6.
2026-07-09 — Phase 5 (Element Web) live: `matrix-element` container serving `element.example.com`
(grey-cloud, Caddy `reverse_proxy element:80`, LE cert issued), config host-side at
`/opt/matrix/element/config.json`.
2026-07-09 — Phase 4 (Authentik SSO / OIDC) live: `oidc_providers` inlined in host
`homeserver.yaml`, login via Authentik verified, `@stefan:example.com` promoted to Synapse admin.
2026-07-08 — Phase 3 (Postgres + Synapse base) deploy.
