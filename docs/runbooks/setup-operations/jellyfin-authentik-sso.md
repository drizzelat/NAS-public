# Runbook: Expose Jellyfin publicly behind Authentik SSO

> **Status: done — Jellyfin is public.** Executed 2026-07-11 on NPMplus, with as-built deviations
> called out inline as **[as-built]** notes. **Since the 2026-09-07 Caddy cutover the edge half is
> different:** the PROXY-protocol listener (step 0) is Caddy's `servers :8443`, the public login
> block (step 6) is the `https://jellyfin.example.com:8443` site block answering `403`, and
> "public vs LAN-only" is a Caddyfile vhost rather than an NPM Access List — see
> [caddy.md](../../services/caddy.md) → Jellyfin's public edge. The NPMplus details below
> (`custom_nginx/` hooks, Access Lists, `proxy_mediaserver`) are the historical record; the
> Authentik, SSO-plugin, QuickConnect and Seerr decisions all still hold.

## Why

Jellyfin is currently **LAN-only** (NPM `444` for outside clients — see
[jellyfin.md](../../services/jellyfin.md) → Common failures). Goal: reach the **web UI** from
the internet without giving out Tailscale/VPN to the whole LAN, using **Authentik** for login —
same single-sign-on story as [mealie](mealie-authentik-oidc.md) / [immich](../../services/immich.md).

Jellyfin is **not** a Mealie-style config flip. Two hard facts from the Jellyfin project + SSO
plugin docs shape everything (verified 2026-07-11, sources at the bottom):

1. **Jellyfin has no native OIDC** and **no reverse-proxy / trusted-header auth.** SSO is a
   third-party plugin (`9p4/jellyfin-plugin-sso`), and it **only works in the web UI**.
2. **The plugin does not disable Jellyfin's native local login**, and it explicitly **does not
   support native mobile/TV apps or Overseerr/Jellyseerr/Seerr.** Those keep using Jellyfin
   username+password.

## The core conflict and how it's resolved

Requirements asked for: (1) expose via VPS, (2) Authentik SSO login, (3) remove Jellyfin login,
(4) keep Seerr working — **Seerr signs in with Jellyfin credentials** (`AuthenticateByName`, a real
Jellyfin username+password).

3 and 4 collide: you can't delete the credential Seerr needs. **Resolution — Seerr is private
(LAN-only), so it never traverses the public path.** That lets us:

- Add SSO for the **web UI** (plugin) → requirement 2.
- **Block the login endpoint at the public edge only** (NPM 403) → requirement 3, for the internet.
- Leave native local auth **fully alive internally**, where Seerr (internal Docker network) and
  LAN/Tailscale apps use it → requirement 4 intact.

So "remove Jellyfin login" means **remove it from the public internet**, not from Jellyfin. Seerr
being private is what makes this clean instead of the cosmetic-only hack.

## Decisions made (and why)

1. **SSO via `9p4/jellyfin-plugin-sso` (OIDC), web UI only.** It's the standard/maintained option;
   Jellyfin has nothing native. Trade-off: third-party plugin, updates via Jellyfin's plugin
   catalog **outside** the repo's `tag@sha256` pinning (not Renovate-controlled), API-only config
   (no admin GUI), no logout-to-IdP callback.
2. **Rejected: filebrowser-style Authentik forward-auth / proxy provider.** Two blockers, both
   confirmed in Jellyfin docs: (a) Jellyfin has **no trusted-header auth**, so behind the Authentik
   wall you'd still hit Jellyfin's own login = **double login**, and it never becomes Jellyfin's
   actual login; (b) forward-auth intercepts every request and **breaks all native clients and the
   API** (they can't do the browser cookie flow). Filebrowser works only because filebrowser
   *honors* proxy-auth headers — Jellyfin doesn't. So the proxy pattern is not usable here.
3. **"Remove login" = block the login endpoint at the public edge, not in Jellyfin.** The plugin
   can't disable native auth, and Seerr/native-apps need it internally. So we return **403 at NPM**
   for the login paths on the public hostname only. Real block on the internet, backend untouched
   for internal use.
4. **Block at NPMplus, not (only) Cloudflare.** Cloudflare WAF can inspect paths **only when
   orange-cloud** (it terminates client TLS at edge). Two reasons NPM is the primary block: it's on
   our infra and always in the path regardless of Cloudflare cloud colour; and **orange-clouding
   Jellyfin risks Cloudflare ToS §2.8** (streaming large video through the proxy) plus proxy
   buffering/timeout on long transcodes. Optionally add the Cloudflare rule too (defense in depth)
   while orange-cloud. If Jellyfin is later switched to **gray-cloud (DNS-only)** for streaming, the
   NPM block still holds; a Cloudflare rule would not.
5. **Seerr stays private (LAN-only), on Jellyfin credentials — not migrated to its own OIDC.** The
   plugin can't help Seerr anyway (unsupported). Seerr reaches Jellyfin over the internal
   `proxy_mediaserver` network, so it's unaffected by the public SSO button *and* the public login
   block. Local Jellyfin passwords are retained for it.
6. **Household Jellyfin accounts keep a local password.** Needed by Seerr and by native apps on
   LAN/Tailscale. SSO provisions/links the account on first web login; set a strong local password
   on it.
7. **QuickConnect enabled + exposed = the off-LAN native-app login path (SSO-gated).** Native apps
   can't do the OIDC redirect and can't hit the (blocked) password endpoint off-LAN. QuickConnect
   fills the gap: the app shows a code, and **approving it requires an already-authenticated web
   session** — the only public way to get one is Authentik SSO (password login is blocked). So
   QuickConnect rides on top of SSO rather than bypassing it. Chosen over "route apps through
   Tailscale" as the primary off-LAN app path. Residual risk = QuickConnect code-relay phishing (see
   gotchas); acceptable for a 2-person household.
8. **Two-person household → no Authentik groups strictly required.** Bind the Authentik application
   to you + gf; that binding is the login allowlist. Optionally map an Authentik group to the
   plugin's `adminRoles` if you want SSO to grant Jellyfin admin, else promote the account once by
   hand.

### Decisions added after the 2026-07-11 security review

1. **Block *all* public password paths, not just `AuthenticateByName`.** Jellyfin has a second
   password endpoint, `POST /Users/{userId}/Authenticate` (by user-id, not name), which the original
   single-line block missed entirely. The user-id is free to obtain: `GET /Users/Public` is
   **unauthenticated** and lists every account with its GUID. So an attacker could enumerate
   `/Users/Public` → grab a GUID → POST `/Users/{id}/Authenticate` with a guessed password, sailing
   past the `AuthenticateByName` 403. Resolution: the edge block covers **both** auth endpoints
   (case-insensitive, incl. the `/emby/` alias) **and** returns 403 on `/Users/Public` publicly (see
   step 6). `/Users/Public` stays reachable on LAN/Tailscale, so the internal user-select splash is
   unaffected. **This is the fix that makes "public login removed" actually true** — without it,
   requirement 3 was silently bypassable.
2. **Restore the real client IP via PROXY protocol (VPS stream → dedicated NPM listener).** Raw
    stream forwarding masks the client IP — every public request reaches NPM (and therefore
    Authentik) as the VPS tailnet IP `100.64.0.12` (see
    [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Security). That makes Authentik's
    per-IP brute-force / reputation policy **useless for the public path** (all attackers look like
    one IP; banning it locks out you + gf). Fix: the VPS stream server sends PROXY protocol; NPM
    reads it and sees the true client IP again — restoring Authentik IP policies, Jellyfin access
    logs, and any future CrowdSec bans, for **all** public sites, not just Jellyfin.
    - **Hard constraint — do NOT flip `proxy_protocol on` on NPM's main `:443`.** LAN/tailnet
      clients connect to NPM `:443` **directly** (AdGuard rewrites the names to the NAS IP; they
      never touch the VPS) and send **no** PROXY header. Turning PROXY protocol on the shared `:443`
      listener breaks every direct LAN/tailnet connection. It must be a **separate, dedicated
      proxy-protocol listener** (e.g. NPM `:8443`) that **only** the VPS forwards to; normal `:443`
      stays plain for LAN. See step 0.
    - **Scope note:** this is shared-ingress infra touching auth/files/immich/mealie too. Build and
      verify it as its own step **before** the Jellyfin cutover — a PROXY-protocol misconfig takes
      down *all* public sites, not just Jellyfin.
3. **QuickConnect kept (reaffirms decision 7).** Off-LAN native-app login stays on QuickConnect,
    SSO-gated. Alternative (disable it, force apps through Tailscale) was reconsidered and rejected
    for a 2-person household. Accept the residual: `/QuickConnect/Initiate` is unauthenticated and
    internet-reachable, and an approved code mints a full long-lived token — so treat it as a
    tokenized login path, not a harmless one. Mitigation rule unchanged: only approve a code you
    generated yourself (see gotchas).
4. **Authentik is now a public-login SPOF, and old tokens outlive the block.** Two accepted
    consequences to keep in mind, not blockers: (a) with password login blocked and SSO the only
    public entry, **Authentik down = zero public Jellyfin login** (LAN/Tailscale still work); (b)
    the edge 403 stops *new* logins only — existing Jellyfin access tokens don't expire and keep
    working off-LAN, so a real cut-off means revoking sessions in the Jellyfin Dashboard, not just
    relying on the block.

## Known limitations to accept (design consequences)

- **Off-LAN native apps (mobile/TV)** can't password-login (endpoint blocked) and can't use SSO
  (plugin is web-only) — they log in **via QuickConnect** (decision 7), approved in an SSO'd web
  session. **Tailscale** remains the fallback for clients that don't support QuickConnect (some
  third-party / Kodi). Web browser off-LAN works via SSO directly.
- **Jellyfin's unauthenticated endpoints stay publicly reachable** (`/System/Info/Public`, etc.,
  plus any future CVE surface). Blocking login ≠ hiding the whole API. This is the residual cost of
  keeping apps working (forward-auth would hide it but breaks apps — decision 2).
- **Attack surface + availability both shift to Authentik** — harden `auth.example.com`
  (brute-force/reputation policy, **mandatory** MFA/TOTP), and accept it as the public-login SPOF
  (review decision 4): Authentik down = no public Jellyfin login. Per-IP policies only work once the
  PROXY-protocol change (review decision 2) restores the real client IP; until then every public
  login looks like `100.64.0.12`.
- **Existing Jellyfin tokens survive the edge block** — the 403 stops new public logins only; tokens
  minted on LAN keep working off-LAN (no default expiry). A hard cut-off = revoke sessions in the
  Jellyfin Dashboard (review decision 4).
- **`/QuickConnect/Initiate` stays unauthenticated + internet-reachable** and an approved code mints
  a full token (review decision 3 / decision 7) — accepted for a 2-person household; rule: only
  approve codes you generated.
- **Plugin is web-UI only and unversioned by our pinning** — a Jellyfin major upgrade can break it;
  check plugin compatibility before bumping the Jellyfin image.
- **Plugin OIDC client secret lives in the Jellyfin config volume** (XML, API-only, no admin GUI) —
  ensure the config volume is in backups and **not** committed to git; after a restore the secret
  must be re-entered via the plugin API (step 3).

## Repo changes required (do in the repo, then push)

Not committed yet — these are the edits this runbook makes:

- `stacks/micro-vps-ingress/docker-compose.yml` — add `jellyfin.example.com` to the `:443` SNI
  allowlist `map` (upstream `100.64.0.11:443`) **and bump the `config-rev` label** (e.g.
  `2026-07-11-add-jellyfin`). Without the bump the VPS nginx silently keeps the old config — see
  [micro-vps-ingress.md](../../services/micro-vps-ingress.md) Common failures.
- `stacks/micro-vps-ingress/docker-compose.yml` (**review decision 2 — PROXY protocol, do as its own
  step 0 first**) — the `:443` stream `server` gets `proxy_protocol on;` and its `map` upstreams
  point at a **dedicated** NPM proxy-protocol port (e.g. `100.64.0.11:8443`), not the shared
  `:443`. Bump `config-rev` again. This changes ingress for **all** public sites (auth/files/immich/
  mealie), so verify them before touching Jellyfin. Update
  [micro-vps-ingress.md](../../services/micro-vps-ingress.md) (the "future Caddy L7 … restore real
  client IPs" note is now done via PROXY protocol) + `network.md`.
- **NPMplus (manual, on the NAS)** — add a dedicated `listen 8443 ssl proxy_protocol;` server that
  only the VPS reaches over Tailscale, keeping the existing `listen 443` (no `proxy_protocol`) intact
  for direct LAN/tailnet clients. **Do not** add `proxy_protocol` to the main `:443` — it breaks
  every direct LAN connection (review decision 2). NPM UI may not expose this; likely a custom
  config snippet. Set `real_ip` from the PROXY header so logs/Access-Lists see the true client IP.
- Docs in the **same** change (AGENTS.md: keep docs in sync): `mediaserver.md` (Jellyfin public,
  SSO plugin + Seerr coupling + login-block), `network.md` (move `jellyfin` from LAN-only to
  "Public, app's own auth"; note SSO plugin + edge login-block; Seerr stays LAN-only),
  `authentik.md` (add Jellyfin OIDC to First-time UI setup), `micro-vps-ingress.md` (allowlist now
  includes jellyfin).

> Jellyfin's compose service needs **no change** — already on `proxy_mediaserver`, and NPM already
> has a `jellyfin.example.com` proxy host. Only its NPM Access List flips + gets the login-block
> `location` (manual steps).

## Step-by-step (do in this order)

> **Order is a safety property**, same as the Mealie runbook: build + prove SSO on the LAN, add the
> login block, and open the front door **last**. Never expose Jellyfin publicly before the block is
> verified.

### 0. Restore real client IP — PROXY protocol (review decision 2, shared ingress)

> **Do this first and verify it independently.** It touches ingress for *all* public sites; a
> misconfig takes them all down. Fully separate from the Jellyfin work — could even be a prior PR.

1. **NPMplus (NAS):** add a dedicated proxy-protocol listener, e.g. `listen 8443 ssl proxy_protocol;`,
   reachable only from the VPS over Tailscale. **Keep the existing `listen 443` without
   `proxy_protocol`** — direct LAN/tailnet clients depend on it. Configure `set_real_ip_from` for the
   VPS tailnet IP + `real_ip_header proxy_protocol` so NPM logs and Access Lists resolve the true
   client IP. (NPM UI may not surface this — likely a custom snippet.)
2. **VPS ingress** (`stacks/micro-vps-ingress/docker-compose.yml`): on the `:443` stream `server`,
   add `proxy_protocol on;` and repoint the `map` upstreams to `100.64.0.11:8443`. Bump
   `config-rev`, push, let Portainer redeploy.
3. **Verify all existing public sites still load off-LAN** (auth/files/immich/mealie) **and** that
   NPM now logs the real client IP, not `100.64.0.12`. If anything breaks, roll back before
   proceeding — Jellyfin is not even in the path yet.

> **[as-built] Two persistence gotchas that broke this mid-run:**
> - **Tailscale ACL** — the admin-console policy restricts what `tag:vps-ingress` may reach on the NAS
>   *by port*. It listed `:443` only, so the moment the VPS repointed to NAS `:8443` **every public
>   site returned Cloudflare `000`/errors** until `:8443` was added to the ACL. Adding the compose
>   port publish is **not** enough — the tailnet ACL must allow `:8443` too.
> - **Docker iptables** — the `8443` ACCEPT rule lives in the `DOCKER` filter chain (nft backend) and
>   is re-added by Docker on every `npm` stack redeploy **because the port is published** in
>   `stacks/npm/docker-compose.yml`. No manual firewall rule to maintain; just don't unpublish `8443`.

### 1. Authentik — OIDC provider + application

UI: `https://auth.example.com`.

1. **Provider** (Applications → Providers → Create) → **OAuth2/OpenID Connect**:
   - Redirect URI: `https://jellyfin.example.com/sso/OID/redirect/authentik`
     (`authentik` = the plugin provider name in step 3 — must match exactly).
   - Signing key: pick one.
   - **Advanced protocol settings → Scopes**: add `openid` + `email` + `profile` (the three
     `authentik default OAuth Mapping: OpenID …` mappings). Missing these = the plugin can't read
     the claims and provisioning fails (same class of bug as Mealie's 401).
   - Note the **Client ID** and **Client Secret**.
2. **Application** (Applications → Applications → Create): slug **`jellyfin`**, bind to the provider,
   add to the **embedded outpost**. Bind the application to you + gf (the login allowlist).
3. *(Optional)* create group `jellyfin-admins` if you want SSO to grant Jellyfin admin via
   `adminRoles` (step 3). Add the group to the provider's scope/claims if so.
4. **(Hardening — required, not optional)** enforce a **mandatory** MFA/TOTP stage for this
   application + a brute-force/reputation policy on Authentik — it's the sole public login surface.
   TOTP is the real public defense; the IP half of the reputation policy only works once step 0
   (PROXY protocol) restores the real client IP, so enrol both you + gf in TOTP before exposing.

### 2. Jellyfin — Known Proxies (do before installing the plugin)

Jellyfin ≥ 10.10.7 only trusts forwarded headers from configured proxies; without this the SSO
redirect URI comes out wrong.

- Dashboard → Networking → **Known Proxies**: add the NPMplus/NAS proxy address that fronts
  Jellyfin (the `proxy_mediaserver` upstream / NPM host IP).
- Set **Published Server URL** to `https://jellyfin.example.com`.
- **Enable Websockets Support on the `jellyfin.example.com` NPM proxy host.** Jellyfin requires a
  WSS upgrade — without it, off-LAN playback state / remote control / session sync break
  intermittently (Jellyfin reverse-proxy docs). Confirm it's toggled on the NPM host (Details tab).

### 3. Jellyfin — install + configure the SSO plugin

1. Dashboard → Plugins → **Repositories** → add:
   `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`
2. Catalog → install **SSO Authentication** → **restart Jellyfin**.
3. Dashboard → Plugins → **SSO-Auth** → add an **OID** provider named exactly **`authentik`**:
   - **OID Endpoint**: `https://auth.example.com/application/o/jellyfin/`
   - **Client ID / Client Secret**: from step 1.
   - **Enabled** ✔.
   - **Enable Authorization by Plugin** ✔ (folder/admin access comes from plugin config, not manual
     per-user setup).
   - **Admin Roles is not optional once "Enable Authorization by Plugin" is ticked.** With that
     box on, the plugin owns `IsAdministrator` and rewrites it on *every* login from the role
     claim, so an empty `AdminRoles` demotes the account each time and no manual promotion
     survives. `RoleClaim` must also be set — it defaults to null, not to `groups`. As-built
     2026-09-08: `RoleClaim = groups`, `AdminRoles = ["authentik Admins"]` (reusing the existing
     Authentik group rather than creating `jellyfin-admins`; note that group also holds `admin`
     and `akadmin`). The `groups` claim rides on the **profile** scope, which the plugin always
     requests. Untick the box instead if you would rather manage admin in Jellyfin.
   - Optional: **Roles** → restrict who may log in at all; **Enable Folder Roles** /
     enable all folders as desired.
   - Save.
4. **Secret handling (review decision 4 / limitations):** the Client Secret is now stored in the
   Jellyfin config volume (plugin XML, API-only — no admin GUI to re-read it). Confirm that volume
   is in your backup set and **never** committed to git. Keep the Client ID/Secret in your password
   manager so it can be re-entered via the plugin after a restore.

### 4. Jellyfin — add the SSO button + hide the native form

- Dashboard → General → **Login Disclaimer** (HTML), paste the plugin's button pointing at the start
  URL:

  ```html
  <form action="https://jellyfin.example.com/sso/OID/start/authentik">
    <button class="raised block emby-button button-submit">Sign in with authentik</button>
  </form>
  ```

- Dashboard → General → **Custom CSS**: hide the built-in username/password form + "Manual Login" so
  the page shows only the SSO button. **Cosmetic only** — the login API is still live (Seerr/LAN
  apps need it); the real public block is step 6.
- Dashboard → General → **enable QuickConnect** — this is the off-LAN native-app login path
  (step 8). Approving a code needs an authenticated web session, and the only public way to get one
  is Authentik SSO, so QuickConnect stays gated behind SSO. (Leave it disabled only if you'd rather
  force apps through Tailscale.)

### 5. Verify SSO on the LAN (still not public)

- LAN browser → `https://jellyfin.example.com` → only the **Sign in with authentik** button →
  click → Authentik → back into Jellyfin logged in.
- First SSO login **provisions/links** a Jellyfin account. Dashboard → Users → that account → set a
  **strong local password** (this is the credential Seerr + native apps use). Confirm it's admin
  (or mapped via group).

### 6. Add the public login block at NPMplus (before exposing)

On the `jellyfin.example.com` NPM proxy host → Advanced → custom Nginx config, return 403 for the
login endpoints (case-insensitive; cover the Emby-compat alias; **do not** block `/sso/`):

```nginx
# Block public password login — Seerr (internal) and LAN/Tailscale apps are unaffected.
location ~* ^/(emby/)?Users/AuthenticateByName$ { return 403; }  # login by username
location ~* ^/(emby/)?Users/[^/]+/Authenticate$ { return 403; }  # login by user-id (review decision 1)
location ~* ^/(emby/)?Users/Public$             { return 403; }  # hide account list + GUIDs (review decision 1)
# /sso/* and /QuickConnect/* MUST stay open — the OIDC flow and the off-LAN app login path.
```

> **[as-built]** NPMplus regenerates the per-host `proxy_host/8.conf` (marked *DO NOT EDIT*) and has
> no writable per-host "Advanced" field on disk, so the block lives in the **file-based
> `custom_nginx/` hooks** instead (same mechanism step 0 used for the `:8443` listener):
> - `custom_nginx/http.conf` — a `map "$host:$server_port" $jf_public_edge { … }` marks requests that
>   arrive on the **public `:8443` edge** for `jellyfin.example.com` (`1`), everything else `0`.
>   LAN/tailnet clients hit `:443` directly, so they never match. This is what makes the block
>   **public-only** — the plain `location ~* …{return 403}` above would have hit LAN clients too.
> - `custom_nginx/server_http.conf` (included in every vhost's `server` block) — combines
>   `$jf_public_edge` with a `set $jf_login_path` flag raised by three `if ($uri ~* …)` tests for the
>   same three endpoints, then `if ($jf_public_edge$jf_login_path = "11") { rewrite ^ /__jf_login_blocked last; }`.
> - The jellyfin host's `8.conf` carries `error_page 401 403 = @deny_drop { return 444; }`, which would
>   turn a naive `return 403` into a `444` drop. To emit a **genuine 403** (the acceptance test wants
>   403, not 444), the target is an `internal` named location that **defines its own `error_page`** —
>   which suppresses inheritance of the server-level 401/403 handler — then `return 403`.
>
> Verified on the NAS by replaying the `:8443` PROXY-protocol edge locally
> (`curl --haproxy-protocol --resolve jellyfin.example.com:8443:127.0.0.1 https://…:8443/…`): all
> three endpoints (+ `/emby/` alias, lowercase) → **403**; `/sso/OID/start/authentik` → 302,
> `/QuickConnect/Initiate` → 400, `/System/Info/Public` → 200; the same paths on `:443` (LAN) are
> unaffected. Reload after editing: `sudo docker exec npmplus nginx -t && … nginx -s reload`.

> Bypass traps this covers: the `/emby/…` alias hits the same endpoint and Jellyfin routing is
> case-insensitive (hence `~*`). **Both** password paths are blocked — `AuthenticateByName` *and*
> the by-user-id `Users/{id}/Authenticate` (review decision 1); blocking only the first was
> bypassable via a GUID pulled from the unauthenticated `/Users/Public`, which is now also 403 on the
> public edge (still open on LAN/Tailscale, so the internal user-select splash works). Do **not**
> block generic `/Users` — it breaks the API. QuickConnect is intentionally **left open** — SSO-gated
> and the off-LAN app login path (decision 7 / review decision 3).

### 7. Open the front door (only after step 6)

1. Push the repo changes (SNI allowlist + `config-rev` bump + docs). The `deploy-stacks` runner
   redeploys `micro-vps-ingress`. Confirm the VPS picked it up:

   ```sh
   ssh ubuntu@198.51.100.10 -p 2222 -i ~/.ssh/ssh-key-vps.key
   sudo docker exec micro-vps-ingress-nginx-1 grep jellyfin /etc/nginx/nginx.conf
   ```

2. **NPM** — flip `jellyfin.example.com` Access List from LAN-only to the public list
   (`allow all;`), matching `immich`/`mealie`.
3. *(Optional, orange-cloud only)* Cloudflare WAF custom rule as a second layer — Block when
   `lower(http.request.uri.path)` matches `/users/authenticatebyname`,
   `/emby/users/authenticatebyname`, `/users/public`, **or** the regex
   `^/(emby/)?users/[^/]+/authenticate$` (the by-user-id path — review decision 1). **Do not** block
   `/quickconnect` or `/sso` (off-LAN app path + OIDC flow). Skip the whole rule if Jellyfin is
   gray-cloud/DNS-only — Cloudflare can't see paths then; the NPM block still holds.

### 8. Verify (the acceptance tests)

- **Web SSO, off-LAN** (mobile data): `https://jellyfin.example.com` shows only the SSO button →
  login works → lands in Jellyfin.
- **Public password login blocked — all paths**: from off-LAN, each of these → **403**:
  - `curl -i -X POST https://jellyfin.example.com/Users/AuthenticateByName`
  - `.../emby/Users/AuthenticateByName`
  - `.../Users/<any-guid>/Authenticate` (by-user-id path — review decision 1)
  - `.../Users/Public` (GET; account list hidden publicly — review decision 1)
  And `/sso/OID/start/authentik` + `/QuickConnect/Initiate` → **not** 403. Also confirm
  `/Users/Public` still returns the list from LAN/Tailscale (splash unaffected).
- **Real client IP in logs** (review decision 2): trigger a login from off-LAN and confirm NPM /
  Authentik logs show your actual public IP, not `100.64.0.12`. If it still shows the VPS IP, step
  0 didn't take — the brute-force policy is blind.
- **Seerr still works** (LAN): sign out/in with **Sign in with Jellyfin** using the account's
  username + local password → authenticates (internal path, unaffected). Seerr itself stays
  LAN-only — this runbook does **not** expose `seerr.example.com`.
- **Native apps, off-LAN via QuickConnect**: in the app pick **Quick Connect** → it shows a code →
  open Jellyfin web, log in via **Authentik SSO**, approve the code → the app gets a session as your
  account. No password typed in-app, no Tailscale needed.
- **Native apps, on LAN/Tailscale**: log in with local username+password → works (endpoint only
  blocked on the public path).

## Difficulties / gotchas

- **Missing OIDC scopes** → provisioning fails (add `openid`+`email`+`profile`, step 1). Same shape
  as Mealie's 401. Also confirm the Authentik user has an email set.
- **Redirect URI mismatch** → set **Known Proxies** + **Published Server URL** (step 2) *before*
  testing; Jellyfin ≥10.10.7 rejects untrusted forwarded headers, breaking the redirect.
  **This re-breaks on any proxy change.** `KnownProxies` is Jellyfin config state, not repo state,
  so the Caddy migration silently invalidated it: the value still named the retired NPM subnet
  `172.16.23.0/24` while Caddy fronted Jellyfin from `proxy_jellyfin`. Untrusted proxy means
  `X-Forwarded-Proto` is dropped, `Request.Scheme` becomes `http`, and the plugin builds
  `http://jellyfin.example.com/sso/OID/redirect/authentik`, which fails the provider's `strict`
  match. Fixed 2026-09-08 to `172.16.33.0/24` + `fdd0:0:0:21::/64` (restart required). That subnet
  is Docker-assigned — `proxy_jellyfin` has no explicit `subnet:` in the Caddy compose, so
  recreating the network can move the CIDR and reproduce this.
- **Login block too broad** → don't block `/sso/`; don't block generic `/Users` (breaks the API).
  Match only the auth endpoints + `/Users/Public`, case-insensitively, incl. the `/emby/` alias.
- **Login block too narrow** (the review's #1 finding) → blocking only `AuthenticateByName` leaves
  the by-user-id path `Users/{id}/Authenticate` open, and `/Users/Public` hands out the GUIDs to use
  it. Block all three (step 6) or "public login removed" is false.
- **PROXY protocol on the wrong listener** → adding `proxy_protocol` to NPM's shared `:443` breaks
  **every direct LAN/tailnet client** (they send no PROXY header). Use a dedicated proxy-protocol
  port that only the VPS reaches (step 0); keep `:443` plain. Symptom of getting it wrong: LAN works
  but public sends garbage, or LAN breaks the moment the listener flips.
- **SNI `config-rev` not bumped** → VPS serves the old allowlist and public Jellyfin is dropped at
  the VPS. Always bump the label.
- **Cloudflare orange-cloud + video** → ToS §2.8 / buffering; prefer gray-cloud for Jellyfin and
  rely on the NPM block (decision 4).
- **QuickConnect code-relay phishing** → an attacker can initiate QuickConnect and try to trick a
  logged-in user into approving *their* code (device-code phishing). Low risk for a 2-person
  household; rule: only approve a code you generated yourself. `/QuickConnect/Initiate` is
  unauthenticated, so the internet can spam it — harmless without an approval, but an approved code
  hands out a full long-lived token. Tailscale is the fallback for clients that don't support
  QuickConnect (some third-party / Kodi).
- **Authentik down = no public Jellyfin login** (review decision 4) → password blocked + SSO the only
  public entry + QuickConnect needs an SSO'd session. During Authentik maintenance, off-LAN access is
  Tailscale-only. Plan Authentik upgrades accordingly.
- **Old tokens survive the block** (review decision 4) → the 403 stops *new* logins only; existing
  Jellyfin access tokens don't expire. To actually revoke access, kill sessions in Dashboard → the
  user's Devices, don't rely on the edge block.
- **Plugin secret lost after a restore** → it lives in the config volume (API-only, no GUI). If the
  volume isn't backed up you must re-enter Client ID/Secret via the plugin API. Keep them in your
  password manager (step 3).

## Last updated

2026-07-11

## Sources (verified 2026-07-11)

- [9p4/jellyfin-plugin-sso README + providers.md](https://github.com/9p4/jellyfin-plugin-sso) —
  manifest URL, OID endpoint/redirect/start URL formats, roles/folder config, "web UI only", "does
  not disable native login", Overseerr/Jellyseerr + native apps unsupported.
- [Jellyfin — Reverse Proxy docs](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/) —
  Known Proxies / Published Server URL, WebSocket requirement, no trusted-header auth.
- [jellyfin/jellyfin #16956 — clients behind external auth gateways](https://github.com/jellyfin/jellyfin/issues/16956)
  and [discussion #16470 — native OIDC for all clients](https://github.com/orgs/jellyfin/discussions/16470) —
  forward-auth breaks native clients/API; no native OIDC.
