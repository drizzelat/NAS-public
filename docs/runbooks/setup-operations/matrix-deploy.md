# Runbook: Deploy a Matrix homeserver (Synapse) on a dedicated Oracle A1

Build a self-hosted **Matrix** homeserver for high-availability messaging, deliberately
run **off the NAS** on its own cloud host so chat keeps working when the NAS is rebooting,
resilvering, or power-cut. Federated with the public Matrix network, single sign-on via the
existing Authentik, and future-proofed for **mautrix bridges** (WhatsApp / Signal / Discord
now; anything later as a 3-line change).

> **Status: live.** Values in `<ANGLE_BRACKETS>` are filled in as you provision. Substitute your own
> for every `example.com` if you copy this elsewhere.

## As built

Live values discovered/decided during the build (fill the `<ANGLE_BRACKETS>` with these):

| Placeholder | Actual value |
| --- | --- |
| `<A1_PUBLIC_IP>` | `198.51.100.20` |
| `<A1_TAILNET_IP>` | `100.64.0.13` |
| `<SSH_PORT>` | `2222` (matches the micro) |
| SSH command | `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20` (public IP — **not** the tailnet IP; tailscale SSH is ACL-blocked and intercepts port 22 on the tailnet interface) |
| Block-volume device | `/dev/sdb`, mounted `/opt/matrix` **by UUID** `153236b6-951d-4118-b45f-12571cea83c1` (since 2026-09-16). Not by `/dev/oracleoci/oraclevda`: the boot disk carries that name too — [os-updates.md](os-updates.md#prerequisite-mount-data-volumes-by-uuid) |

**State:** Phases 1–6 are built — host, DNS delegation, Synapse, Authentik SSO, Element Web and the
WhatsApp bridge. Signal and Discord bridges are not started (6.3). Backups run
([a1-matrix-backup](../backup-restore/a1-matrix-backup.md)). The configs that the phases below
describe as host files under `/opt/matrix/` are now inline `configs:` in the compose file, with
secrets from Komodo Variables ([a1-vps-matrix.md](../../services/a1-vps-matrix.md)); the bridge's
own `config.yaml` + `registration.yaml` are still host files.

Gotchas from the build that the phases do not already carry:

- **Authentik "Client identifier (client_id) is missing or invalid"** at the authorize step means
  the pasted client id does not match the provider's. Discovery and `jwks` answering `200` does
  **not** validate it; that only surfaces at authorize.
- **A dead WhatsApp device store after repeated link/unlink** (`store is nil`, `invalid use of
  deleted device`): `docker restart matrix-mautrix-whatsapp` reloads the device from the DB.
- **"Switch to native Matrix when the contact has it" is impossible self-hosted.** WhatsApp gives the
  bridge no signal about a contact's Matrix presence; that feature is Beeper-proprietary.
- Harmless log noise: `org.matrix.msc2965/auth_{metadata,issuer}` → `404`, and `Failed to listen on
  0.0.0.0 … continuing because listening on [::]`.

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
> `ALLOW_PASSWORD_LOGIN` pattern — see [mealie.md](../../services/mealie.md).

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
> hardening, Docker, Tailscale, Komodo periphery) is its own reusable runbook
> — [a1-provision.md](a1-provision.md) — and for this deployment it's **already done**: the A1
> `a1-matrix` (`instance-20260708-0942`, tailnet `100.64.0.13`). **This A1 is the Matrix host — Matrix is all it
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

7. **Deploy path = the normal one.** The stack lives at **`stacks/a1-vps-matrix/`**; its `[[stack]]`
   entry in `komodo/resources.toml` puts it on Server `a1-vps`, and `deploy-stacks` deploys it
   through the A1's periphery ([deploy-stacks.md](deploy-stacks.md)). Anything the compose file
   references outside the repo is a **host bind mount under `/opt/matrix/`** (data, and the
   bridge's runtime-mutable `config.yaml` + `registration.yaml`), which you bootstrap by hand
   **before** the stack folder lands on `main`. Secrets go in the vault
   ([secret-sync.md](secret-sync.md)).

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
     is the current state. If an apex rewrite is ever added back in AdGuard, the NAS
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

`${PG_PASS}` comes from the Komodo Variable `A1_VPS_MATRIX__PG_PASS`: put it in the vault with
`scripts/secrets.sh edit a1-vps-matrix`, then `scripts/secrets.sh komodo-vars a1-vps-matrix` before
merging ([secret-sync.md](secret-sync.md)). CI never decrypts the vault.

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

Commit `stacks/a1-vps-matrix/` with its `[[stack]]` entry and `owned-stacks` line and merge to
`main`. `deploy-stacks` creates the Komodo Stack and starts it.
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
there ([mealie.md → Common failures](../../services/mealie.md#common-failures)).

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
Decide exposure: public, or keep it LAN-only via the NAS Caddy if you prefer. Mobile/desktop apps
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
