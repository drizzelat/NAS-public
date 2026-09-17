# Runbook: Deploy a Matrix homeserver (Synapse) on a dedicated Oracle A1

Build a self-hosted **Matrix** homeserver for high-availability messaging, deliberately
run **off the NAS** on its own cloud host so chat keeps working when the NAS is rebooting,
resilvering, or power-cut. Federated with the public Matrix network, single sign-on via the
existing Authentik, and future-proofed for **mautrix bridges** (WhatsApp / Signal / Discord
now; anything later as a 3-line change).

> **Status: live — Phase 6 (WhatsApp bridge) done; Signal/Discord bridges not started.** Nightly
> backups to the NAS run since 2026-08-21 ([a1-matrix-backup](../backup-restore/a1-matrix-backup.md)),
> and since the same day the configs this runbook describes as host files are inline `configs:` in
> the compose file ([a1-vps-matrix.md](../../services/a1-vps-matrix.md)). See the **Deployment log**
> below for exactly where this stands and how to resume. Values in `<ANGLE_BRACKETS>` are filled in as you provision.
> Substitute your own for every `example.com` if you copy this elsewhere.

## Deployment log (resume here)

Live values discovered/decided during the build (fill the `<ANGLE_BRACKETS>` with these):

| Placeholder | Actual value |
| --- | --- |
| `<A1_PUBLIC_IP>` | `198.51.100.20` |
| `<A1_TAILNET_IP>` | `100.64.0.13` |
| `<SSH_PORT>` | `2222` (matches the micro) |
| SSH command | `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20` (public IP — **not** the tailnet IP; tailscale SSH is ACL-blocked and intercepts port 22 on the tailnet interface) |
| Block-volume device | `/dev/sdb`, mounted `/opt/matrix` **by UUID** `153236b6-951d-4118-b45f-12571cea83c1` (since 2026-09-16). Not by `/dev/oracleoci/oraclevda`: the boot disk carries that name too — [os-updates.md](os-updates.md#prerequisite-mount-data-volumes-by-uuid) |

**Phase 1 — host prep: ✅ COMPLETE (2026-07-08).**
- Instance `instance-20260708-0942`, arm64, Ubuntu 24.04, resized to **2 OCPU / 12 GB**.
- Firewall: Security List + host iptables allow 80/443/2222 (and still 22 in the Security List — optional to close).
- **SSH moved to 2222, 22 closed.** Gotcha: Ubuntu 24.04 ssh is **socket-activated** — the port is set in `ssh.socket`, *not* `sshd_config Port` (the runbook/a1-provision Phase 3 text is wrong on this). Override lives at `/etc/systemd/system/ssh.socket.d/override.conf`. A bare `ListenStream=<port>` makes **IPv6-only** listeners → all IPv4/public SSH is refused (self-lockout). Must list **both** families: `ListenStream=0.0.0.0:2222` **and** `ListenStream=[::]:2222`. Verify a real external IPv4 connection before dropping the old port.
- Docker + Compose installed; Tailscale joined.
- **DNS fix (required):** tailscale MagicDNS (`CorpDNS`, override-local-DNS) hijacked system DNS to `100.100.100.100`, which failed → all `docker pull`/public lookups broke. Fixed & persists: `sudo tailscale set --accept-dns=false` (NAS reached by IP, not MagicDNS). Confirmed: `docker pull` works, `tailscale ping nas` → pong.
- **Block volume:** 100 GB attached (console), `mkfs.ext4`, fstab with the `x-systemd.*` docker-ordering guard, mounted `/opt/matrix` (~98 GB). The fstab source was `/dev/oracleoci/oraclevda` until 2026-09-16, now the UUID. Attach is a console/OCI action — no OCI CLI on host or workstation.
- **Break-glass while SSH is down:** the Portainer agent (endpoint 5 `a1-vps`, token in gitignored `secrets/portainer-migrate.config.ps1`) can run a privileged `--pid=host` container that chroots `/host` and runs `systemctl`. Agent image is distroless (no shell) — side-load `busybox` via `POST /api/endpoints/5/docker/images/load` (host DNS may be down, so a normal pull won't work). This is how SSH was recovered mid-build.

**Phase 2 — Cloudflare DNS: ✅ COMPLETE (2026-07-08).** On `example.com`:
1. `A  matrix  198.51.100.20` — **Proxy: DNS only (grey cloud)**. Verified: public DNS returns
   `198.51.100.20` (not a CF proxy IP).
2. Redirect Rule — When `Hostname eq example.com` AND `URI Path starts_with /.well-known/matrix/`; Then dynamic redirect `concat("https://matrix.example.com", http.request.uri.path)`, 301, preserve query. Verified: `example.com/.well-known/matrix/server` → `301 Location: https://matrix.example.com/.well-known/matrix/server` at the CF edge.

- **LAN split-horizon: ✅ DONE (2026-07-08).** Both fixes applied: (a) AdGuard DNS rewrite
  `matrix.example.com → 198.51.100.20` overrides the `*.example.com → NAS` wildcard (no NPM
  proxy host added); (b) at the time, a `/.well-known/matrix/` redirect on the apex NPM proxy host
  mirrored the CF redirect. **(b) is no longer needed:** the bare apex is not rewritten in AdGuard
  any more, so LAN clients get the Cloudflare redirect like everyone else (verified 2026-09-11:
  `301` to `matrix.example.com`), and NPM is gone. Full note in Phase 2 §4 below.

**Phase 3 — Postgres + Synapse base: ✅ COMPLETE (2026-07-08).** Homeserver live and federating.

- Stack `stacks/a1-vps-matrix/` (postgres 18-alpine + synapse v1.156.0 + caddy 2, all pinned `@sha256`) deployed via GitOps to endpoint 5. `PG_PASS` in `secrets.enc/portainer-env/a1-vps-matrix.env.age`.
- Host files bootstrapped under `/opt/matrix/` **before** the merge: `synapse/homeserver.yaml` (+ signing key, backed up to `/opt/matrix/_backup/` — **still stash in Bitwarden**), `synapse/appservices/`, `caddy/Caddyfile`. Postgres data on the block volume.
- **Config gotcha (fixed in this runbook):** `url_preview_enabled: true` makes Synapse refuse to start unless `url_preview_ip_range_blacklist` is also set ("you must specify an explicit target IP address blacklist"). First deploy crash-looped on this; added the standard blacklist (see 3.3) and restarted. Deploy health-check passed after the fix.
- Break-glass local `@admin:example.com` created (3.6); password in Bitwarden. `password_config.enabled: false` normally — flip true + restart to use it.
- **Verified (3.7):** `federationtester.matrix.org` → `FederationOK: true`; `/_matrix/federation/v1/version` → Synapse 1.156.0 over HTTPS (Caddy LE cert issued); apex + `matrix` `.well-known/{server,client}` all return correct JSON.

**Phase 4 — Authentik SSO (OIDC): ✅ COMPLETE (2026-07-09).** Login via Authentik works; `@stefan:example.com` is a Synapse admin.

- Authentik OAuth2/OIDC provider `Matrix` + application slug `matrix` (issuer `https://auth.example.com/application/o/matrix/`), scopes `openid + email + profile`, redirect `https://matrix.example.com/_synapse/client/oidc/callback`. App bound to the account = login allowlist.
- `oidc_providers` block **inlined in `/opt/matrix/synapse/homeserver.yaml`** (Synapse does **not** expand env vars there — client id/secret are literal in the host file, never in git; backup at `homeserver.yaml.bak-preoidc`). `synapse.handlers.oidc` preloads the provider on boot and fetches `.well-known/openid-configuration` + `jwks` → both `200`.
- Login verified via `app.element.io` → homeserver `https://matrix.example.com` → **Continue with Authentik** → lands as `@stefan:example.com`. Promoted admin: `UPDATE users SET admin=1` on `matrix-postgres` (confirmed `admin=1`).
- **Gotcha:** first attempt failed at the Authentik authorize step with *"Client identifier (client_id) is missing or invalid"* — the pasted client_id didn't match the provider's actual value. Re-copied the exact **Client ID** from Provider → Matrix → Protocol settings; restart; login worked. (Discovery/jwks `200` does **not** validate client_id — that only surfaces at authorize.)
- **Harmless log noise:** `org.matrix.msc2965/auth_{metadata,issuer}` → `404` (next-gen-auth probing) and `Failed to listen on 0.0.0.0 … continuing because listening on [::]` (dual-stack quirk; `[::]` covers IPv4).

**Phase 5 — Element Web: ✅ COMPLETE (2026-07-09).** Browser client live at `https://element.example.com`.

- `element` service (`vectorim/element-web:v1.12.23`, pinned `@sha256`) added to `stacks/a1-vps-matrix/docker-compose.yml`; deployed via GitOps to endpoint 5. arm64 image (A1 is aarch64).
- Config host-side at `/opt/matrix/element/config.json` (`default_server_config` → `base_url https://matrix.example.com`, `server_name example.com`; `disable_guests`, `default_country_code DE`). Bind mount — bootstrapped **before** the compose push (else Docker auto-creates it as a directory).
- Exposure: **Cloudflare grey-cloud** `A element 198.51.100.20`; Caddy site block `element.example.com { reverse_proxy element:80 }` appended to `/opt/matrix/caddy/Caddyfile` (backup `Caddyfile.bak-preelement`), `caddy reload`. LE cert issued via HTTP-01.
- LAN split-horizon: AdGuard DNS rewrite `element.example.com → 198.51.100.20` (public IP, hairpin) overrides the `*.example.com → NAS` wildcard.
- **Verified:** `https://element.example.com` → HTTP 200, `/config.json` serves correct homeserver, LE cert valid.

**Phase 6 — WhatsApp bridge: ✅ COMPLETE (2026-07-09).** `mautrix-whatsapp` (bridgev2,
`v0.2606.0`, pinned `@sha256`, arm64) live on `matrix_net`; shared `doublepuppet` appservice in
place so own-account messages appear as `@stefan`. Signal/Discord not yet deployed.

- **Shared double-puppet appservice (6.0.1) built:** `/opt/matrix/synapse/appservices/doublepuppet.yaml`
  (namespace `@.*:example.com`, non-exclusive); tokens hand-generated. Wired into
  `homeserver.yaml` `app_service_config_files`; the bridge references it via
  `double_puppet.secrets: { example.com: as_token:<TOKEN> }`.
- **DB** `mautrix_whatsapp` created `LC_COLLATE=C`. Config/registration are host bind mounts under
  `/opt/matrix/bridges/whatsapp/` (a compose change is a git push; a *config* change is SSH + edit +
  `docker restart`).
- **Gotchas hit + fixed (all folded into Phase 6.2 below):**
  1. **Stale image via lexical tag sort** — `v0.9.0` (a 2023 bridgev1 build) sorts *above*
     `v0.26xx` as a string; it logged "outdated WhatsApp web protocol". Re-pinned to the
     numerically-latest CalVer tag `v0.2606.0` (bridgev2). Required wiping the bridge dir + DB.
  2. **`sender_localpart` random** → Synapse `403 "Application service has not registered this
     user (@whatsappbot)"`. Forced `sender_localpart: whatsappbot`.
  3. **`PermissionError`** crash-loop — root-owned `registration.yaml` copy unreadable by Synapse;
     `chown --reference` the appservices dir + `chmod 644`.
  4. **E2EE `/sync` 500** — `NotImplementedError`, "We no longer support AS users using /sync".
     Switched to `encryption.appservice: true` (MSC3202) + `experimental_features` in
     `homeserver.yaml`.
  5. **`502 Connection refused`** on the appservice ping — bridgev2 defaults
     `appservice.hostname: 127.0.0.1`; set `0.0.0.0`, and `appservice.address:
     http://mautrix-whatsapp:29318` (service name, not localhost).
  6. **WhatsApp history/old chats never imported (`whatsapp_history_sync_notification` = 0
     across every relink)** — the *actual* blocker. The generated config ships **top-level
     `backfill.enabled: false`**, so the bridge never requests message history from the phone
     nor stores history-sync payloads. Symptom is deceptive: contacts + group **portals still
     appear** (that's *app-state* sync, independent of backfill) so it looks half-working.
     Fix: set top-level `backfill: enabled: true` (leave `backfill.queue.enabled: false` —
     the queue is Beeper-only; Synapse can't MSC2716-insert, so history lands as a forward
     backfill into each new portal at creation). Also set the network block
     `network.history_sync.request_full_sync: true` + `full_sync_config.days_limit: 1095` to
     pull ~3 yr instead of 3 mo. **Both only take effect on a genuinely fresh device pair** —
     `logout` in the bot room + remove the linked device on the phone, then `login qr`. After a
     fresh pair with backfill on: 214 conversations / 32 545 messages staged, then drained into
     portals. Old media may fail with `download ... status code 403 / no url present` — that's
     expired media purged from WhatsApp's servers (text still backfills; ♻️ can't recover it).
     A secondary trap during diagnosis: repeated link/unlink **without restarting the bridge**
     leaves a dead in-memory device store (`store is nil` / `Returning noop device in
     GetStore` / `invalid use of deleted device`) after a `device_removed` — `docker restart
     matrix-mautrix-whatsapp` reloads the device from the DB and clears it.
  7. **Red shield on every bridged message + wrong contact names + chats bumped by contact
     re-sync** — three found on first real use, all avoidable at setup:
     - **Shield (`"The sender of the event does not match the owner of the device that sent
       it"`)** — Synapse was missing `msc3202_device_masquerading` and
       `msc3984_appservice_key_query` from `experimental_features` (only 3 of the 5 flags were
       set; the earlier runbook wrongly claimed masquerading needs no flag). Without them the
       bridge can't encrypt as the puppet's device and clients can't fetch the puppet's device
       keys. Add both, restart Synapse. **Not retroactive** — messages already backfilled keep
       their shields; only history re-paired *after* the flags are set is clean.
     - **Wrong names** — `network.displayname_template` shipped without `.FullName`/`.FirstName`,
       so address-book names (present in `whatsmeow_contacts.full_name`) were never used; contacts
       showed self-set WhatsApp name or number. Fix: lead the template with
       `{{or .FullName .FirstName …}}`.
     - **Contact re-sync bumps every chat** — running a manual contact sync *after* portals exist
       rewrites each ghost's profile; those `m.room.member` state events sort as recent activity
       and float every chat to the top with no real message. With the `.FullName` template, the
       one automatic sync-on-link already names portals correctly — never manually re-sync.
     Because none of these are retroactively fixable, the clean path (no important data yet) was:
     set the 5 MSC flags + fixed template + QoL (`archive_tag: m.lowpriority`,
     `enable_status_broadcast: false`) → `logout` + purge portals/rooms + wipe the
     `mautrix_whatsapp` portal/message/history/crypto tables → one fresh `login qr`.
- **Verified:** `Homeserver -> appservice connection works`, `End-to-bridge encryption is in
  appservice mode`, `Bridge started`; container `RestartCount=0`. WhatsApp account link (QR) is the
  user step. **History import verified** after enabling `backfill.enabled` (see gotcha 6): a fresh
  pair staged 214 conversations / 32 545 messages, which drained into portals.
- **Auto-switch to native Matrix when the contact also has Matrix: not built — impossible
  self-hosted.** WhatsApp gives the bridge no signal about a contact's Matrix presence; the
  "detect the other side, switch transport" feature is Beeper-proprietary (server-side, closed).
  Double puppeting (own messages show as you) *is* enabled; native Matrix with a contact is a manual
  separate DM if they share their MXID.

**Phase 7+ — Signal/Discord, backups: ⬜ NOT STARTED.**

## Design decisions (locked)

| Decision | Choice | Why |
| --- | --- | --- |
| Homeserver | **Synapse** (reference impl) | Best appservice/bridge support — the whole point of "future-proof for bridges". conduwuit/Dendrite are lighter but bridge support is patchier. |
| Host | **Oracle Ampere A1** (`a1-matrix`, arm64, always-free), dedicated to Matrix | The ingress micro is 954 MB — far too small. A1 gives up to 4 OCPU / 24 GB free. A datacenter host beats the N100 + no-UPS + CGNAT home box on every availability axis. Separate from the NAS = separate blast radius. |
| `server_name` | **`example.com`** (permanent), delegated to `matrix.example.com` | Clean IDs `@stefan:example.com`. **Irreversible** — baked into every user/room ID. |
| Federation | **Open**, delegated to `:443` | Reach the wider Matrix network. Delegation to 443 means **no need to expose 8448**. |
| Public exposure | `matrix.example.com` **DNS-only (grey-cloud)** through Cloudflare; TLS by Caddy on the A1 | Reliable federation (CF orange-cloud can inject challenge pages that break S2S), and no CF 100 MB media-upload cap. Only the A1 IP is exposed — the NAS origin stays hidden. |
| `.well-known` | Served by the A1; apex `example.com/.well-known/matrix/*` **redirected to the A1 by a Cloudflare rule** | Federation/client discovery has **zero NAS dependency**. |
| Auth | **Authentik SSO (OIDC)** only + a **break-glass local admin** | Consistent with immich/mealie. See the availability caveat below. |
| Bridges | **mautrix** WhatsApp, Signal, Discord (extensible) | Most mature bridge family; shared appservice plumbing. |
| Backups | Nightly `pg_dump` + media → **NAS over Tailscale** → existing Hetzner offsite | Message history (incl. bridged WhatsApp/Signal/Discord content) lands in your existing 3-2-1 chain; you keep the data even though it runs in the cloud. |

> **Availability caveat you accepted (SSO-only).** Login goes through Authentik on the NAS.
> If the NAS is down: existing Element sessions, all federation, and every bridge **keep
> working** (access tokens don't re-auth) — only *new* logins fail. The **break-glass local
> admin** (Phase 3, created via shared secret) is the recovery path: temporarily flip
> `password_config.enabled: true` and log in locally. This mirrors the Mealie
> `ALLOW_PASSWORD_LOGIN` pattern — see [mealie-authentik-oidc.md](mealie-authentik-oidc.md).

## Architecture at a glance

```text
                         Internet
                            │
          ┌─────────────────┴──────────────────┐
          │                                     │
   client + federation                  federation discovery
   matrix.example.com                 example.com/.well-known/matrix/*
   (Cloudflare DNS-only)                (Cloudflare orange)
          │                                     │
          │                          Cloudflare Redirect Rule
          │                          → matrix.example.com/.well-known/…
          ▼                                     │
   ┌──────────────────────────────────────────▼───────────────────┐
   │  Oracle Ampere A1  (arm64, dedicated, public IP)              │
   │                                                               │
   │  Caddy :80/:443  ── TLS (Let's Encrypt) ──┐                   │
   │     /.well-known/matrix/{server,client}   │  serves JSON      │
   │     /_matrix/*  /_synapse/client/*        │  → synapse:8008   │
   │                                           ▼                   │
   │  Synapse (homeserver)  ── OIDC ──▶ auth.example.com (NAS)   │
   │     app_service_config_files: [ whatsapp, signal, discord ]   │
   │                                                               │
   │  mautrix-whatsapp / -signal / -discord   (appservices)        │
   │                                                               │
   │  Postgres 18  (synapse + one DB per bridge, LC_COLLATE=C)     │
   │  Element Web (optional)                                       │
   │                                                               │
   │  Tailscale ──────── nightly pg_dump + media ────▶ NAS         │
   └───────────────────────────────────────────────────────────────┘
```

## Phase 0 — Prerequisites

| You need | Notes |
| --- | --- |
| Oracle Cloud account with a free **A1** allocation available | You already use the AMD micro for ingress; A1 is a **separate** always-free allocation. Capacity can be region-limited — see Phase 1 fallback. |
| Cloudflare access to `example.com` | To add the `matrix` record and the apex `.well-known` redirect rule. |
| Authentik admin (`auth.example.com`) | To create the OIDC provider + application. |
| NAS reachable over Tailscale | Backup target (`nas` = `100.64.0.11`). |
| A workstation | To edit configs and drive the deploy over SSH. |
| The phones/accounts to bridge | WhatsApp (phone with the app), Signal (phone number), Discord (token/login) for Phase 6. |

## Phase 1 — Provision the Oracle A1 host

> **Shortcut — the host already exists.** The generic build (instance, both firewall layers, SSH
> hardening, Docker, Tailscale, Portainer agent) is its own reusable runbook
> — [a1-provision.md](a1-provision.md) — and for this deployment it's **already done**: the A1
> `a1-matrix` (`instance-20260708-0942`, tailnet `100.64.0.13`) is provisioned and currently
> runs only the Portainer agent + Tailscale. **This A1 is the Matrix host — Matrix is all it
> runs.** The public ingress stays on the **AMD micro**, so nothing contends for host ports 80/443
> and there is nothing to co-locate. Two deltas remain before Matrix fits:
> **resize** the A1 in place from its as-built 1 OCPU / 5.8 GB to **2 OCPU / 12 GB** (survives
> reboot), and **add a block volume** for `/opt/matrix` (step 3). The Matrix-specific pieces are
> steps 3 (block volume) and 7 (deploy path); steps 1–2 and 4–6 are the a1-provision recap,
> already satisfied on this host.

1. **Create the instance.** Oracle Cloud → Compute → Instances → Create.
   - Shape: **Ampere A1 Flex**, e.g. **2 OCPU / 12 GB** (free tier allows up to 4/24 — 2/12 is
     ample for Synapse + Postgres + 3 bridges with headroom).
   - Image: **Ubuntu 24.04 LTS (aarch64)**.
   - Boot volume: default (~47 GB) is fine for the OS; media/DB go on a block volume (step 3).
   - Add your **SSH public key** (reuse `~/.ssh/ssh-key-vps.key` or generate a dedicated Matrix
     key and store it in the age vault — see [secret-sync.md](secret-sync.md)).
   - **Capacity fallback:** if launch fails with *"Out of host capacity"* (common for A1), either
     retry in another AD/region, use a capacity-notification script, **or** provision a **Hetzner
     CAX11** (arm, 2 vCPU / 4 GB, ~€3.8/mo) instead — every step below is identical from Phase 2 on
     (arm64, Ubuntu, Docker). If you use Hetzner, cap `max_upload_size` lower and give Postgres
     tighter memory limits.

2. **Firewall — both layers.** Oracle Ubuntu images ship restrictive **iptables** *and* the
   cloud **Security List / NSG**; you must open ports in **both** (this bit the ingress micro —
   see [micro-vps-ingress.md](../../services/micro-vps-ingress.md)).
   - Cloud Security List (VCN → Security Lists) — ingress allow:
     - TCP `<SSH_PORT>` (pick a non-standard port, key-only, like the micro's 2222)
     - TCP `80` (ACME HTTP-01 + HTTP→HTTPS redirect)
     - TCP `443` (client-server + federation)
   - Host iptables — persist the same (Oracle images use `netfilter-persistent`):
     ```sh
     sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
     sudo iptables -I INPUT -p tcp --dport 80  -j ACCEPT
     sudo iptables -I INPUT -p tcp --dport <SSH_PORT> -j ACCEPT
     sudo netfilter-persistent save
     ```
   - **Do not** open 8448 — federation is delegated to 443.

3. **Attach a block volume for data** (Oracle always-free includes up to 200 GB block storage).
   Create a ~100 GB volume, attach (paravirtualized), then:
   ```sh
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS     # the new disk: 100G, no FSTYPE, e.g. sdb
   sudo mkfs.ext4 /dev/sdX
   sudo mkdir -p /opt/matrix
   echo "UUID=$(sudo blkid -s UUID -o value /dev/sdX) /opt/matrix ext4 defaults,_netdev,nofail,x-systemd.required-by=docker.service,x-systemd.before=docker.service 0 2" | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload
   sudo mount /opt/matrix
   ```
   Mount **by UUID**. `/dev/oracleoci/oraclevda` is claimed by the boot disk as well, and a boot
   where the boot disk wins the name leaves Docker down.
   All service data lives under `/opt/matrix/…` so it's on the (backed-up, resizable) volume.
   The two `x-systemd.*` options tie Docker to the mount: with plain `nofail`, a volume that
   fails to attach at boot would let Docker start anyway and silently write container data to
   the **boot volume** under the empty `/opt/matrix` mountpoint (split-brain that's painful to
   untangle). This way a failed mount keeps Docker down — loud, not silent — while `nofail`
   still lets the host boot so you can SSH in and fix it.

4. **Harden SSH.** Move sshd to `<SSH_PORT>`, `PasswordAuthentication no`, `PermitRootLogin no`;
   install **fail2ban** (the micro lacks it — don't repeat that gap):
   ```sh
   sudo apt update && sudo apt install -y fail2ban
   ```

5. **Install Docker + Compose** (arm64):
   ```sh
   curl -fsSL https://get.docker.com | sudo sh
   sudo systemctl enable --now docker
   ```
   Leave `ubuntu` out of the `docker` group (use `sudo docker`), matching the micro's convention.

6. **Join the tailnet** (native package, like the micro):
   ```sh
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --accept-routes --ssh
   ```
   Note the new **A1 tailnet IP** → `<A1_TAILNET_IP>`. Approve it in the Tailscale admin console.
   Verify it can reach the NAS: `tailscale ping nas`.

7. **Deploy path = normal GitOps.** The stack lives at **`stacks/a1-vps-matrix/`** — the
   `a1-vps-*` prefix is what routes it: the deploy workflow
   ([deploy-stacks.yml](../../../.github/workflows/deploy-stacks.yml)) deploys `a1-vps-*`
   folders to the **A1 Portainer Agent endpoint** (agent installed in
   [a1-provision.md](a1-provision.md)). No repo clone on the host is needed: everything the
   compose file references outside the repo is a **host bind mount under `/opt/matrix/`**
   (Synapse config, Caddyfile, bridge configs, runtime-mutable `registration.yaml`), which you
   bootstrap by hand in Phases 3–6 **before** the stack folder lands on `main`. Secrets go in
   `secrets.enc/portainer-env/a1-vps-matrix.env` ([secret-sync.md](secret-sync.md)).

## Phase 2 — DNS & delegation (Cloudflare)

1. **`matrix.example.com` → A1, DNS-only.** Cloudflare → DNS → add:
   - `A  matrix  <A1_PUBLIC_IP>`  — **Proxy status: DNS only (grey cloud).**

   Grey-cloud is deliberate: federation and large media must reach the A1 without Cloudflare's
   edge in the path. (Trade-off: the A1 IP is public. It's a disposable, hardened, NAS-independent
   host — acceptable. Orange-cloud alternative works for the client API but risks S2S breakage and
   caps uploads at 100 MB.)

2. **Apex `.well-known` redirect → the A1.** Cloudflare → Rules → **Redirect Rules** → Create:
   - **When**: `Hostname equals example.com` **AND** `URI Path starts with /.well-known/matrix/`
   - **Then**: Dynamic redirect →
     `concat("https://matrix.example.com", http.request.uri.path)`, status **301**, preserve
     query string.

   This makes `https://example.com/.well-known/matrix/server` (fetched by every federating
   server) resolve to the A1's JSON **at the Cloudflare edge** — no NAS, no origin hit. Matrix
   discovery follows the redirect per spec.

3. Leave the rest of `example.com` untouched — the apex/other subdomains still flow through the
   ingress micro to the NAS as today.

4. **LAN split-horizon override (required for LAN clients). ✅ DONE (2026-07-08)** — both the
   AdGuard rewrite and the apex `.well-known` redirect below are in place and verified.
   On the LAN, AdGuard rewrites
   `*.example.com` → the NAS IP so every subdomain lands on the NAS edge proxy
   ([adguard.md](../../services/adguard.md), [caddy.md](../../services/caddy.md)). That wildcard
   **misroutes `matrix.example.com` to the NAS**, where the edge has no vhost for it — so Matrix
   is unreachable from LAN clients even though public DNS (Cloudflare) correctly returns the A1.
   Do **not** add a vhost for it — that re-adds the NAS dependency this whole build
   avoids. Instead add an AdGuard **DNS rewrite** that overrides the wildcard for the exact name:
   - AdGuard → Filters → **DNS rewrites** → `matrix.example.com` → **`198.51.100.20`** (the A1
     public IP). A more-specific rewrite wins over `*.example.com`. Use the **public** IP, not
     the A1 tailnet IP — it works from every LAN device via hairpin and matches public DNS.
     (Add the same for `element.example.com` if you host Element Web in Phase 5.)
   - **Apex `.well-known` on LAN** — as long as AdGuard does **not** rewrite the bare apex
     `example.com`, LAN clients resolve it publicly and hit the Phase 2 Cloudflare redirect like
     everyone else, so `@stefan:example.com` auto-discovery works with nothing on the NAS. That
     is the current state (verified 2026-09-11). At build time AdGuard *did* rewrite the apex to
     the NAS, and a `location /.well-known/matrix/ { return 301 … }` on the apex NPM proxy host
     mirrored the Cloudflare rule; both are gone. If an apex rewrite is ever added back, the NAS
     Caddy needs a `example.com` site with
     `redir /.well-known/matrix/* https://matrix.example.com{uri} 301` — the `*.example.com`
     wildcard site does not cover the apex. Federation is unaffected either way — federating
     servers use public DNS.
   - This rewrite (and any LAN test) only *responds* once **Phase 3** brings up Caddy + Synapse —
     nothing serves `matrix.example.com` before that. Federation (server-to-server) is unaffected
     either way: federating servers use public DNS, never the LAN resolver.

## Phase 3 — Postgres + Synapse base

Files live in `stacks/a1-vps-matrix/` in this repo (the `a1-vps-*` prefix routes the deploy to
the A1 — see Phase 1.7); runtime data under `/opt/matrix/` on the host.

> **Order matters:** prepare the host-side files (3.2–3.4) **before** merging the stack folder
> to `main` — the moment `stacks/a1-vps-matrix/` lands on `main`, the workflow deploys it, and a
> bind-mounted file that doesn't exist yet (e.g. the Caddyfile) gets auto-created as a
> *directory* by Docker, which then has to be cleaned up by hand.

### 3.1 Compose (base services)

`stacks/a1-vps-matrix/docker-compose.yml` (bridges added in Phase 6):

```yaml
services:
  postgres:
    image: postgres:18-alpine        # pin tag@sha256 to match repo convention before committing
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${PG_PASS}
      POSTGRES_DB: synapse
      # Synapse REQUIRES C locale on its DB — set at initdb time:
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --lc-collate=C --lc-ctype=C"
    volumes:
      # postgres 18+ layout: mount the PARENT dir, not the versioned PGDATA subdir —
      # required for in-place pg_upgrade to a future major version
      - /opt/matrix/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse"]
      interval: 30s
      timeout: 5s
      retries: 5
    networks: [matrix_net]

  synapse:
    image: ghcr.io/element-hq/synapse:latest   # pin tag@sha256 before committing
    container_name: matrix-synapse
    restart: unless-stopped
    environment:
      SYNAPSE_CONFIG_DIR: /data
      SYNAPSE_CONFIG_PATH: /data/homeserver.yaml
    volumes:
      - /opt/matrix/synapse:/data
    depends_on:
      postgres: { condition: service_healthy }
    networks: [matrix_net]

  caddy:
    image: caddy:2-alpine            # pin before committing
    container_name: matrix-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/matrix/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/matrix/caddy/data:/data
      - /opt/matrix/caddy/config:/config
    networks: [matrix_net]

networks:
  matrix_net:
    name: matrix_net
```

> **Pin every image `tag@sha256:digest` before you commit** — repo rule (Renovate manages the
> pins). `latest` above is a placeholder for the first pull only.

`${PG_PASS}` is supplied by Portainer at deploy time: put it in
`secrets/portainer-env/a1-vps-matrix.env`, encrypt to `secrets.enc/portainer-env/a1-vps-matrix.env`
and commit — [secret-sync.md](secret-sync.md). `scripts/secrets.sh push a1-vps-matrix` creates the
stack with that env and applies every later change; CI never decrypts the vault.

### 3.2 Generate the initial Synapse config

```sh
sudo docker run --rm -v /opt/matrix/synapse:/data \
  -e SYNAPSE_SERVER_NAME=example.com \
  -e SYNAPSE_REPORT_STATS=no \
  ghcr.io/element-hq/synapse:latest generate
```

This writes `/opt/matrix/synapse/homeserver.yaml` + signing key. **Back up the signing key
(`example.com.signing.key`) immediately** — losing it breaks your server's federation identity
permanently.

### 3.3 Edit `homeserver.yaml`

Key settings (merge into the generated file):

```yaml
server_name: "example.com"
public_baseurl: "https://matrix.example.com/"
pid_file: /data/homeserver.pid

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true          # behind Caddy
    resources:
      - names: [client, federation]
        compress: false

database:
  name: psycopg2
  args:
    user: synapse
    password: "<PG_PASS value>"  # inline the real value — this file lives on the host, never in
                                 # git, and Synapse does NOT expand env vars in homeserver.yaml
    dbname: synapse
    host: postgres
    cp_min: 5
    cp_max: 10

# Registration: closed. Accounts are created by SSO (Phase 4) or the break-glass admin.
enable_registration: false
registration_shared_secret: "<LONG_RANDOM>"   # for register_new_matrix_user (admin/bridge bots)

# Password login OFF for humans (SSO only). Break-glass: flip true + restart to use local admin.
password_config:
  enabled: false

# Media
max_upload_size: 100M
url_preview_enabled: true
# REQUIRED whenever url_preview_enabled is true — Synapse refuses to start without it
# ("you must specify an explicit target IP address blacklist"). Blocks SSRF to internal ranges.
url_preview_ip_range_blacklist:
  ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10',
   '192.0.0.0/24', '169.254.0.0/16', '198.18.0.0/15', '192.0.2.0/24', '198.51.100.0/24',
   '203.0.113.0/24', '224.0.0.0/4', '::1/128', 'fe80::/10', 'fc00::/7', '2001:db8::/32',
   'ff00::/8', 'fec0::/10']

# Federation is ON by default (open). Delegated to :443 via .well-known (Phase 2).
suppress_key_server_warning: true

# Appservices — bridges register here (Phase 6):
app_service_config_files: []
#  - /data/appservices/doublepuppet.yaml        # shared double-puppet appservice (6.0.1)
#  - /data/appservices/mautrix-whatsapp.yaml
#  - /data/appservices/mautrix-signal.yaml
#  - /data/appservices/mautrix-discord.yaml
```

Create the appservice dir now: `sudo mkdir -p /opt/matrix/synapse/appservices`.

### 3.4 Caddyfile

`/opt/matrix/caddy/Caddyfile`:

```caddy
matrix.example.com {
    # Federation delegation target + client discovery (also reached via the apex redirect)
    handle /.well-known/matrix/server {
        header Content-Type application/json
        respond `{"m.server": "matrix.example.com:443"}`
    }
    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond `{"m.homeserver": {"base_url": "https://matrix.example.com"}}`
    }
    # Synapse client-server + server-server API
    handle /_matrix/* {
        reverse_proxy synapse:8008
    }
    handle /_synapse/client/* {
        reverse_proxy synapse:8008
    }
}
```

Caddy auto-provisions the Let's Encrypt cert for `matrix.example.com` via HTTP-01 (port 80 is
open, grey-cloud lets LE reach the origin).

### 3.5 Bring it up

Commit `stacks/a1-vps-matrix/` + the encrypted env file and merge to `main`. The deploy workflow
sees the new `a1-vps-*` folder, creates the stack on the A1 Portainer endpoint and starts it.
Then on the A1:

```sh
sudo docker logs -f matrix-synapse    # watch for "Synapse now listening on TCP port 8008"
```

Subsequent compose changes deploy the same way — push to `main`, the webhook redeploys.

### 3.6 Create the break-glass local admin

```sh
sudo docker exec -it matrix-synapse register_new_matrix_user \
  -c /data/homeserver.yaml -u admin -a http://localhost:8008
# -a = admin. Store the password in Bitwarden. This is your recovery account.
```

### 3.7 Verify federation (do not skip)

- `curl https://matrix.example.com/_matrix/federation/v1/version` → JSON version.
- `curl https://example.com/.well-known/matrix/server` → `{"m.server":"matrix.example.com:443"}`
  (proves the Cloudflare redirect + Caddy well-known).
- **Federation Tester:** open `https://federationtester.matrix.org/#example.com` → **all green**.
  This is the authoritative check that `@you:example.com` federates.

## Phase 4 — Authentik SSO (OIDC)  ✅ DONE (2026-07-09)

Mirror the Mealie OIDC pattern — including the **scopes gotcha** that cost you a debugging session
there ([mealie-authentik-oidc.md](mealie-authentik-oidc.md) "Difficulties").

1. **Authentik → Providers → Create → OAuth2/OpenID Connect:**
   - Redirect URI (strict): `https://matrix.example.com/_synapse/client/oidc/callback`
   - Signing key: pick your default.
   - **Advanced protocol settings → Scopes:** add **openid + email + profile** (`authentik
     default OAuth Mapping`). *Without email+profile, Synapse gets only `sub` and account
     provisioning fails* — the exact Mealie trap.
   - Note the **Client ID** and **Client Secret**.
2. **Authentik → Applications → Create:** slug **`matrix`** (must match the issuer path below),
   bind to the provider. Bind the app to your account (+ household). That binding is the login
   allowlist.
3. **Add the OIDC block to `homeserver.yaml`:**
   ```yaml
   oidc_providers:
     - idp_id: authentik
       idp_name: "Authentik"
       issuer: "https://auth.example.com/application/o/matrix/"
       client_id: "<CLIENT_ID>"
       client_secret: "<CLIENT_SECRET>"
       scopes: ["openid", "profile", "email"]
       user_mapping_provider:
         config:
           localpart_template: "{{ user.preferred_username }}"
           display_name_template: "{{ user.name }}"
           email_template: "{{ user.email }}"
   ```
   Restart Synapse: `sudo docker restart matrix-synapse`.
4. **First SSO login → promote to admin.** Log into Element (Phase 5 / any client) with
   "Continue with Authentik". Synapse auto-creates `@stefan:example.com`. Make it admin:
   ```sh
   sudo docker exec matrix-postgres \
     psql -U synapse -c "UPDATE users SET admin=1 WHERE name='@stefan:example.com';"
   ```
5. **Test** in a private window: the login page should offer **Continue with Authentik**;
   local password login is hidden (`password_config.enabled: false`). Confirm the break-glass
   admin still works only after flipping `enabled: true` + restart (leave it `false` normally).

## Phase 5 — Element Web (optional client)  ✅ DONE (2026-07-09)

Nice-to-have browser client; you can also just use Element X (mobile) / Element Desktop and skip
this. To host it, add to the compose:

```yaml
  element:
    image: vectorim/element-web:latest    # pin before committing
    container_name: matrix-element
    restart: unless-stopped
    volumes:
      - /opt/matrix/element/config.json:/app/config.json:ro
    networks: [matrix_net]
```

`/opt/matrix/element/config.json` → set `default_server_config` to `base_url:
https://matrix.example.com` and `server_name: example.com`. Add a Caddy site block for
`element.example.com` (`reverse_proxy element:80`) and a matching grey-cloud DNS record.
Decide exposure: public, or keep it LAN-only via the NAS/NPM if you prefer. Mobile/desktop apps
don't need this at all.

## Phase 6 — Bridges (mautrix)

All mautrix bridges follow the **same shape**, so once one is wired the rest are copy-paste. The
plumbing is built now so adding a future bridge (Telegram, Slack, Google Messages, …) is a 3-line
change.

### 6.0 Shared model

- One **Postgres DB per bridge** on the existing `postgres` service.
- Each bridge is one **container** on `matrix_net`, config + data under
  `/opt/matrix/bridges/<name>/`.
- Each bridge generates a **`registration.yaml`** that Synapse loads via
  `app_service_config_files`. **Copy it into `/opt/matrix/synapse/appservices/` and restart
  Synapse** so it trusts the appservice.
- **Double puppeting (SSO-compatible):** use the modern mautrix **appservice method** — but
  **not** with each bridge's own `as_token`: a bridge's registration namespace only covers its
  ghost users (`@whatsapp_*…`), so Synapse rejects an appservice login as `@stefan`. Instead,
  register **one dedicated `doublepuppet` appservice** whose user namespace covers all local
  users (6.0.1); every bridge shares its token. This needs **no password login**, so it works
  under your SSO-only setup. (The older `login_shared_secret` method needs password login and is
  *not* used here.)

#### 6.0.1 One-time: the shared double-puppet appservice

Hand-write `/opt/matrix/synapse/appservices/doublepuppet.yaml` (one per homeserver — no bridge
generates this):

```yaml
id: doublepuppet
url:                                     # token-only appservice — Synapse never pushes events to it
as_token: "<DOUBLEPUPPET_TOKEN>"         # long random; every bridge references this token
hs_token: "<LONG_RANDOM>"                # required by the schema, never used
sender_localpart: doublepuppet-unused    # required by the schema, never used
rate_limited: false
namespaces:
  users:
    - regex: '@.*:example\.com'
      exclusive: false                   # non-exclusive: matches real users, claims none
```

Add `/data/appservices/doublepuppet.yaml` to `app_service_config_files:` in `homeserver.yaml`
and `sudo docker restart matrix-synapse`. Every bridge then sets
`double_puppet.secrets: { "example.com": "as_token:<DOUBLEPUPPET_TOKEN>" }`.

### 6.1 Create the bridge databases

```sh
sudo docker exec matrix-postgres psql -U synapse -c \
  "CREATE DATABASE mautrix_whatsapp WITH TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C';"
# repeat for mautrix_signal, mautrix_discord
```

### 6.2 Bring up one bridge (WhatsApp shown; Signal/Discord identical)

Add to compose:

```yaml
  mautrix-whatsapp:
    # CalVer tags (e.g. v0.2606.0 = 2026-06). Do NOT trust a lexical tag sort —
    # v0.10/v0.26xx sort *below* v0.9.0 as strings. Pick the numerically-highest tag,
    # pin tag@sha256 before committing. (v0.9.0 is a stale 2023 bridgev1 build.)
    image: dock.mau.dev/mautrix/whatsapp:v0.2606.0@sha256:3ecf348ac3451199fe1e7b894469bd8cf9b2abe58699f3b9a8029172c4356877
    container_name: matrix-mautrix-whatsapp
    restart: unless-stopped
    volumes:
      - /opt/matrix/bridges/whatsapp:/data
    depends_on:
      postgres: { condition: service_healthy }
    networks: [matrix_net]
```

> **Modern mautrix = "bridgev2".** The current images use the bridgev2 config schema
> (top-level `database:`, `network:`, `matrix:`; `double_puppet.secrets` — matching this runbook).
> The old bridgev1 schema — `appservice.database`, `login_shared_secret_map` — is a different
> layout; don't mix a bridgev1 config with a bridgev2 image (or vice-versa). If you generated a
> config with the wrong version, wipe `/opt/matrix/bridges/whatsapp/`, DROP+recreate the DB
> (nothing is linked yet), and regenerate.

Bootstrap order (this order matters — the bridge writes its registration before Synapse can
trust it). Generate the config with a **one-off `docker run`** so the container isn't crash-looping
under GitOps while you edit — cleaner than push→stop:

1. **First run generates config:**
   ```sh
   sudo mkdir -p /opt/matrix/bridges/whatsapp
   sudo docker run --rm -v /opt/matrix/bridges/whatsapp:/data \
     dock.mau.dev/mautrix/whatsapp:<PINNED> ; # writes config.yaml, then exits
   ```
2. **Edit `config.yaml`** (bridgev2 keys):
   - `homeserver.address: http://synapse:8008`, `homeserver.domain: example.com`
   - **`appservice.hostname: 0.0.0.0`** (bridgev2 defaults to `127.0.0.1` → Synapse in another
     container gets `502 Connection refused` on the appservice ping. Must bind all interfaces.)
   - `appservice.address: http://mautrix-whatsapp:29318` (the service name on `matrix_net`, **not**
     `localhost` — that's how Synapse reaches the bridge)
   - `database.uri: postgres://synapse:<PG_PASS>@postgres/mautrix_whatsapp?sslmode=disable`
     (top-level `database:` in bridgev2, not `appservice.database`)
   - `bridge.permissions: { "@stefan:example.com": admin }` (drop the `"*": relay` default)
   - `encryption.allow: true`, `encryption.default: true`, **`encryption.appservice: true`**
     (see the E2EE gotcha below)
   - `double_puppet.secrets: { "example.com": "as_token:<DOUBLEPUPPET_TOKEN>" }` — the shared
     token from 6.0.1, **not** this bridge's own `as_token`
   - **QoL / display (set at generate time so portals are born correct — see gotcha 7):**
     - `network.displayname_template: '{{or .FullName .FirstName .BusinessName .PushName .Phone .RedactedPhone "Unknown user"}} (WA)'`
       — **lead with `.FullName .FirstName`** (your phone address-book names). The generated
       default omits them and starts at `.BusinessName`/`.PushName`, so contacts show their
       self-set WhatsApp name or bare number instead of the name you saved. (Contacts you never
       saved have no `.FullName` and fall through to push-name/number — unavoidable.)
     - `network.enable_status_broadcast: false` — skip the WhatsApp Status/Stories room entirely
       (otherwise it bridges as a noisy low-priority room).
     - `network.archive_tag: m.lowpriority` — archived WhatsApp chats map to Matrix low-priority
       (ships empty). `pinned_tag: m.favourite` already ships set.
     - Already on by default in bridgev2 (leave as-is): `personal_filtering_spaces: true`
       (all portals grouped under one WhatsApp Space), `sync_direct_chat_list: true` (1:1 chats
       land in Element's People/Direct), `private_chat_portal_meta: true`.
     - `network.history_sync.request_full_sync: true` + `full_sync_config.days_limit: 1095`
       and top-level **`backfill.enabled: true`** — the history-import switch (gotcha 6).
3. **Generate the registration** (second run) and **fix `sender_localpart`:**
   ```sh
   sudo docker run --rm -v /opt/matrix/bridges/whatsapp:/data \
     dock.mau.dev/mautrix/whatsapp:<PINNED> ; # writes registration.yaml
   # mautrix generates a RANDOM sender_localpart, but the bot is @whatsappbot. Synapse then
   # refuses the bot's own connectivity check with 403 "Application service has not registered
   # this user" (an AS may only masquerade as its sender or an already-created ghost). Pin the
   # sender to the bot so @whatsappbot == sender and the check passes:
   sudo sed -i 's/^sender_localpart:.*/sender_localpart: whatsappbot/' \
       /opt/matrix/bridges/whatsapp/registration.yaml
   ```
4. **Wire the registration into Synapse** (fix ownership — a root-owned `cp` is unreadable by the
   Synapse user and crash-loops it with `PermissionError`):
   ```sh
   sudo cp /opt/matrix/bridges/whatsapp/registration.yaml \
           /opt/matrix/synapse/appservices/mautrix-whatsapp.yaml
   sudo chown --reference=/opt/matrix/synapse/appservices/doublepuppet.yaml \
           /opt/matrix/synapse/appservices/mautrix-whatsapp.yaml
   sudo chmod 644 /opt/matrix/synapse/appservices/mautrix-whatsapp.yaml
   ```
   Add `/data/appservices/mautrix-whatsapp.yaml` to `app_service_config_files:` in
   `homeserver.yaml`, add the **E2EE experimental features** (next bullet), then
   `sudo docker restart matrix-synapse`.
   - **E2EE-over-appservice (MSC3202) — required.** With `encryption.appservice: true` the bridge
     receives encryption data over appservice transactions, because **Synapse refuses `/sync` for
     appservice users** (`NotImplementedError` → 500: "We no longer support AS users using /sync").
     Enable the transport in `homeserver.yaml`:

     ```yaml
     experimental_features:
       msc3202_transaction_extensions: true
       msc3202_device_masquerading: true      # REQUIRED — bridge encrypts AS each puppet device
       msc2409_to_device_messages_enabled: true
       msc3983_appservice_otk_claims: true
       msc3984_appservice_key_query: true      # REQUIRED — clients fetch puppet device keys to verify
     ```

     The generated registration already carries `org.matrix.msc3202: true` +
     `de.sorunome.msc2409.push_ephemeral: true` when `encryption.appservice: true` was set at
     generate time.
     - **All FIVE flags are required — do NOT omit `msc3202_device_masquerading` or
       `msc3984_appservice_key_query`.** Missing them is silent: the bridge starts, messages
       bridge and decrypt, but every bridged message shows a **red shield** in Element —
       *"The sender of the event does not match the owner of the device that sent it."* Without
       `device_masquerading` the bridge can't encrypt as the puppet's own device; without
       `appservice_key_query` clients can't query the puppet's device keys to match it to the
       sender. Both gaps produce the identical shield. This is **not retroactively fixable** —
       messages backfilled under the broken config keep their shields forever; only a clean
       re-pair after the flags are set produces clean history (see gotcha 7).
5. **Deploy + start the bridge:** commit the compose image pin, push to `main` (GitOps recreates
   the container with the host-side config/registration bind mounts already in place). Verify:
   `docker logs matrix-mautrix-whatsapp` shows `Homeserver -> appservice connection works`,
   `End-to-bridge encryption is in appservice mode`, `Bridge started`.
6. **Link your account:** DM `@whatsappbot:example.com` in Element → send `login qr` → scan the
   QR with WhatsApp → Settings → Linked Devices → Link a Device. (`login phone +<number>` gives a
   pairing code instead.) Chats start bridging; with `double_puppet.secrets` set, messages you send
   from the WhatsApp app appear as **you** (`@stefan`), not the bot.
   - **Let the single automatic sync pass complete — do NOT manually run a contact re-sync
     afterward (gotcha 7).** On link, whatsmeow does one app-state (contacts) + history pass;
     with the `.FullName` template above, portals are created with the right names on the first
     try. Manually re-syncing contacts after portals exist rewrites every ghost's profile, and
     those `m.room.member` state events bump every chat to the top of Element's recent-activity
     list with no real message. One clean pass, then leave it.
7. **Set up Element key backup (recovery key) — do this once, on YOUR account.** Element →
   Settings → Security & Privacy → Secure Backup → *Set up* → save the generated **recovery key**
   (store in Bitwarden). Without it, re-logging in or adding a device leaves you unable to read
   your own encrypted history. This is client-side, unrelated to the bridge, but it's the step
   people forget until they're locked out.

### 6.3 Signal & Discord

Repeat 6.1–6.2 with `dock.mau.dev/mautrix/signal` and `dock.mau.dev/mautrix/discord`, their own
DBs and `/opt/matrix/bridges/<name>/` dirs, their registrations added to
`app_service_config_files`. Login flows: Signal = link as a linked device; Discord = token or
QR login. Per-bridge options: <https://docs.mau.fi/bridges/>.

### 6.4 Adding a future bridge later

1. `CREATE DATABASE mautrix_<x> …` (LC_COLLATE C).
2. Add the container, first-run to generate config, edit config (homeserver/DB/permissions/
   double-puppet), copy `registration.yaml` into `appservices/`, add the one line to
   `app_service_config_files`, restart Synapse, start the bridge.

## Phase 7 — Backups → NAS over Tailscale

Fold Matrix into the existing 3-2-1 chain: dump on the A1 → ship to the NAS over Tailscale → the
NAS's nightly Hetzner Cloud Sync carries it offsite. See
[postgres-dump.md](../backup-restore/postgres-dump.md) and [backup.md](../backup-restore/backup.md).

1. **On the NAS**, create a dataset to receive dumps, e.g. `/mnt/apps/matrix-backup/`, ensure
   it's inside the Hetzner Cloud Sync source set, **and give it periodic snapshots** — the script
   mirrors with `--delete`, so snapshots (not the mirror) are your point-in-time history.
2. **One-time: SSH trust A1 → NAS.** The script runs as root (cron), so it's **root's** key:
   ```sh
   sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
   sudo cat /root/.ssh/id_ed25519.pub   # append to truenas_admin's authorized_keys on the NAS
   sudo ssh truenas_admin@100.64.0.11 true   # accept the host key once; must exit 0
   ```
3. **On the A1**, `/opt/matrix/backup.sh`:
   ```sh
   #!/usr/bin/env bash
   set -euo pipefail
   ts=$(date +%F)
   out=/opt/matrix/_backup
   mkdir -p "$out"
   # enumerate DBs live — works before any bridge exists, auto-covers future bridges
   dbs=$(docker exec matrix-postgres psql -U synapse -At -c \
     "SELECT datname FROM pg_database WHERE datname='synapse' OR datname LIKE 'mautrix\_%';")
   for db in $dbs; do
     docker exec matrix-postgres pg_dump -U synapse "$db" | gzip > "$out/$db-$ts.sql.gz"
   done
   # signing key + configs (small, critical); nullglob so a bridge-less server doesn't
   # pass the unexpanded glob to tar and die under set -e
   shopt -s nullglob
   cfg=(/opt/matrix/synapse/*.yaml /opt/matrix/synapse/*.signing.key /opt/matrix/bridges/*/config.yaml)
   tar czf "$out/matrix-config-$ts.tgz" "${cfg[@]}"
   rsync -a --delete "$out/" \
       truenas_admin@100.64.0.11:/mnt/apps/matrix-backup/latest/
   # --delete: exact mirror, no unbounded growth; deleted media survives in NAS snapshots
   rsync -a --delete /opt/matrix/synapse/media_store/ \
       truenas_admin@100.64.0.11:/mnt/apps/matrix-backup/media/
   find "$out" -mtime +7 -delete
   ```
4. **Schedule** it nightly as **root** (systemd timer or cron) *before* the NAS's Hetzner sync
   window. Add a row to [scheduled-tasks.md](../../scheduled-tasks.md).
5. **The signing key is the crown jewel** — losing it permanently breaks federation identity.
   It's in the config tarball above; also stash a copy in Bitwarden.

## Phase 8 — Monitoring & hardening

- **Uptime Kuma** ([kuma-monitors.md](kuma-monitors.md)): add HTTP monitors for
  `https://matrix.example.com/_matrix/federation/v1/version` and a keyword monitor on the
  Federation Tester. Because the A1 is off-NAS, monitor it from **both** the NAS Kuma and the VPS
  Kuma so a NAS outage doesn't blind you to a Matrix outage.
- **Synapse rate limiting**: keep the defaults; tighten `rc_login` / `rc_registration` if abused.
- **Registration is closed** (`enable_registration: false`) — the main open-federation risk is
  spam invites/rooms. Future: a moderation bot (**Draupnir/Mjolnir**) and
  `block_non_admin_invites` if it becomes a problem.
- **fail2ban** on SSH (installed Phase 1). Consider CrowdSec later
  ([crowdsec-bouncer.md](crowdsec-bouncer.md)) if you add an L7 proxy.
- **Portainer:** the A1 Agent endpoint (set up in [a1-provision.md](a1-provision.md)) is the
  deploy path here, not just visibility — `stacks/a1-vps-matrix/` deploys through it via
  [deploy-stacks.yml](../../../.github/workflows/deploy-stacks.yml) like every other stack.

## Phase 9 — Verification checklist

- [ ] Federation Tester green for `example.com`.
- [ ] `curl https://example.com/.well-known/matrix/{server,client}` returns the JSON.
- [ ] SSO login via Authentik creates/authenticates `@stefan:example.com`.
- [ ] Break-glass: flip `password_config.enabled: true`, log in as `@admin`, flip back.
- [ ] Join a public federated room (e.g. `#matrix:matrix.org`) — proves S2S.
- [ ] Each bridge: DM the bot, `login`, a real chat mirrors into Matrix.
- [ ] Double-puppet: messages you send from the native app show as **you** (not the bot) in Matrix.
- [ ] Nightly backup lands in `/mnt/apps/matrix-backup/` on the NAS and rides the Hetzner sync.
- [ ] Kuma monitors green from NAS **and** VPS.
- [ ] Reboot the A1 → everything returns (`restart: unless-stopped` + docker enabled at boot).

## Future extensions (the "future-proof" part)

- **Voice/video 1:1 calls** — deploy **coturn** (TURN) on the A1; it needs a UDP port range
  opened in both firewall layers. Point Synapse `turn_uris` at it.
- **Group calls** — **Element Call + LiveKit** SFU (a separate container set); the modern
  successor to Jitsi widgets. Fits on the A1 or its own host.
- **More bridges** — Telegram, Slack, Google Messages, Instagram, LinkedIn: all mautrix, all via
  the Phase 6.4 recipe.
- **Sliding Sync** — now built into Synapse (Simplified Sliding Sync); Element X uses it natively,
  no separate `sliding-sync` proxy needed on current Synapse.
- **Moderation** — Draupnir bot + policy rooms once federation traffic grows.
- **Media offloading** — S3-compatible media store (e.g. to the NAS or Backblaze) if media grows
  past the block volume.

## Repo changes this runbook produces

When you execute it, commit in this order (one-line subjects, no trailer — repo commit style):

1. `feat(stacks): add a1-vps-matrix homeserver stack` — `stacks/a1-vps-matrix/` (compose +
   Caddyfile + `homeserver.yaml` template + bridge config templates + a `README`) **plus**
   `secrets.enc/portainer-env/a1-vps-matrix.env` (age-encrypted `PG_PASS`). The `a1-vps-` prefix
   is load-bearing: it's what makes deploy-stacks.yml target the A1 endpoint. **Never commit real
   secrets in the clear** — OIDC client secret, `registration_shared_secret`, `as_token`s, and
   the **signing key** live in host-side config under `/opt/matrix/` / the age vault, not the repo.
2. `docs(services): add a1-vps-matrix service doc` — `docs/services/a1-vps-matrix.md` from `_template.md`
   (Access = SSO; Volumes = `/opt/matrix/*`; Dependencies = Authentik, Postgres, Caddy, Tailscale;
   Operations = restart/upgrade/restore/common-failures).
3. `docs: register matrix host + ports` — `docs/network.md` (the A1 host row, `matrix.example.com`
   grey-cloud note, that federation is delegated to :443 and 8448 is **not** exposed) and, if you
   add the Portainer agent, `docs/services/micro-vps-ingress.md`-style host notes for the A1.
4. `docs: schedule matrix backup` — row in `docs/scheduled-tasks.md`.
5. `docs(runbooks): index matrix deploy runbook` — add this file to
   [runbooks/README.md](../README.md).

> *(Superseded 2026-08-21: the configs are inline `configs:` in the compose file with secrets from
> the vault; only the bridge's own `config.yaml` + `registration.yaml` stay host-side —
> [a1-vps-matrix.md](../../services/a1-vps-matrix.md) → Operations. The note below is the build-time
> state.)*
>
> **One deviation worth documenting:** the stack deploys via normal Portainer GitOps, but its
> *configs* (`homeserver.yaml`, Caddyfile, bridge configs, `registration.yaml`) are **host-side
> files under `/opt/matrix/`**, bootstrapped and edited by hand on the A1 — the Portainer Agent
> can't carry sibling files, and mautrix rewrites `registration.yaml` at runtime. Note this in
> `docs/services/a1-vps-matrix.md` → Operations: a compose change is a git push, a *config*
> change is SSH + edit + `docker restart`.

## Last updated

2026-07-09 — Phase 6 (WhatsApp bridge) live: `mautrix-whatsapp` bridgev2 `v0.2606.0` (pinned,
arm64) + shared `doublepuppet` appservice deployed via GitOps; `mautrix_whatsapp` DB (LC_COLLATE
C); E2EE over appservice (MSC3202) with `experimental_features` added to `homeserver.yaml`. Five
gotchas fixed and folded into Phase 6.2 (stale lexical tag → CalVer pin, random `sender_localpart`,
appservices file ownership, AS-user `/sync` 500 → MSC3202, bridgev2 `hostname 127.0.0.1` → 0.0.0.0).
Auto-switch to native Matrix for Matrix-having contacts documented as **not possible** self-hosted
(Beeper-only). WhatsApp QR link is the remaining user action. Signal/Discord not started.

2026-07-09 — Phase 5 (Element Web) complete: `element` service (`vectorim/element-web:v1.12.23`,
arm64, pinned) deployed via GitOps; host config `/opt/matrix/element/config.json`; Caddy block +
Cloudflare grey-cloud `element` record + AdGuard rewrite added; served at `element.example.com`
(HTTP 200, LE cert). Host files bootstrapped before the compose push per the bind-mount ordering rule.

2026-07-09 — Phase 4 (Authentik SSO / OIDC) complete: provider+app `matrix` created, `oidc_providers`
inlined in host `homeserver.yaml`, login verified via Element (`Continue with Authentik` →
`@stefan:example.com`), account promoted to Synapse admin. Gotcha logged: wrong client_id paste
fails only at the Authentik authorize step, not at boot-time discovery.

2026-07-08 — Phase 3 (Postgres + Synapse base) deployed and verified: homeserver live at
`matrix.example.com`, Federation Tester green, break-glass admin created. Fixed the
`url_preview_ip_range_blacklist` requirement that crash-looped the first deploy. Phase 2 LAN
split-horizon (AdGuard `matrix` rewrite + apex NPM `.well-known` redirect) applied — LAN clients
now reach the homeserver. Signing key backed up encrypted to `secrets.enc/ssh/`.
