# Runbook: Expose Jellyfin publicly behind Authentik SSO

> **Status: done — Jellyfin is public.** The edge half lives in the Caddyfile: the public login
> block is the `https://jellyfin.example.com:8443` site block answering `403`
> ([caddy.md → Jellyfin's public edge](../../services/caddy.md#jellyfins-public-edge)). This runbook
> keeps the Authentik, SSO-plugin, QuickConnect and Seerr side, and how to rebuild it.

## Why

Goal: reach the **web UI** from
the internet without giving out Tailscale/VPN to the whole LAN, using **Authentik** for login —
same single-sign-on story as [mealie](../../services/mealie.md) / [immich](../../services/immich.md).

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
- **Block the login endpoint at the public edge only** (Caddy `403`) → requirement 3, for the internet.
- Leave native local auth **fully alive internally**, where Seerr (internal Docker network) and
  LAN/Tailscale apps use it → requirement 4 intact.

So "remove Jellyfin login" means **remove it from the public internet**, not from Jellyfin. Seerr
being private is what makes this clean instead of the cosmetic-only hack.

## Decisions made (and why)

1. **SSO via `9p4/jellyfin-plugin-sso` (OIDC), web UI only.** It's the standard/maintained option;
   Jellyfin has nothing native. Trade-off: third-party plugin, updates via Jellyfin's plugin
   catalog **outside** the repo's `tag@sha256` pinning (not Renovate-controlled), API-only config
   (no admin GUI), no logout-to-IdP callback.
2. **Rejected: Authentik forward-auth / proxy provider.** Two blockers, both
   confirmed in Jellyfin docs: (a) Jellyfin has **no trusted-header auth**, so behind the Authentik
   wall you'd still hit Jellyfin's own login = **double login**, and it never becomes Jellyfin's
   actual login; (b) forward-auth intercepts every request and **breaks all native clients and the
   API** (they can't do the browser cookie flow). So the proxy pattern is not usable here.
3. **"Remove login" = block the login endpoint at the public edge, not in Jellyfin.** The plugin
   can't disable native auth, and Seerr/native-apps need it internally. So the edge returns **403**
   for the login paths on the public hostname only. Real block on the internet, backend untouched
   for internal use.
4. **Block at the edge proxy, not Cloudflare.** Jellyfin is **gray-cloud (DNS-only)**: orange-clouding
   it risks Cloudflare ToS §2.8 (streaming video through the proxy) plus buffering on long
   transcodes, and a gray-cloud name gives Cloudflare no view of paths. The Caddy block is always
   in the path.
5. **Seerr stays private (LAN-only), on Jellyfin credentials — not migrated to its own OIDC.** The
   plugin can't help Seerr anyway (unsupported). Seerr reaches Jellyfin inside the `jellyfin`
   stack, so it's unaffected by the public SSO button *and* the public login
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

### Decisions added after a security review

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
2. **The real client IP must reach Authentik.** Without it every public login looks like the VPS
    tailnet IP `100.64.0.12`, and Authentik's per-IP brute-force policy is useless. The VPS sends
    PROXY protocol to Caddy's dedicated `:8443` listener only; plain `:443` stays PROXY-free for
    LAN/tailnet clients ([caddy.md → The `:8443` PROXY-protocol listener](../../services/caddy.md#the-8443-proxy-protocol-listener)).
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
  (review decision 4): Authentik down = no public Jellyfin login.
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

## Step-by-step (do in this order)

> **Order is a safety property**: build + prove SSO on the LAN, add the login block, and open the
> front door **last**. Never expose Jellyfin publicly before the block is verified.

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
   TOTP is the real public defense, so enrol both you + gf in TOTP before exposing.

### 2. Jellyfin — Known Proxies (do before installing the plugin)

Jellyfin ≥ 10.10.7 only trusts forwarded headers from configured proxies; without this the SSO
redirect URI comes out wrong.

- Dashboard → Networking → **Known Proxies**: the subnet Caddy reaches Jellyfin from, `proxy_jellyfin`
  (`docker network inspect proxy_jellyfin`, IPv4 and IPv6). Restart Jellyfin after changing it.
- Set **Published Server URL** to `https://jellyfin.example.com`.

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

### 6. Add the public login block (before exposing)

The `https://jellyfin.example.com:8443` site block in the Caddyfile answers `403` for, case-
insensitively and including the `/emby/` alias:

- `Users/AuthenticateByName` (login by username);
- `Users/{id}/Authenticate` (login by user-id — review decision 1);
- `Users/Public` (the account list and its GUIDs — review decision 1).

`/sso/*` and `/QuickConnect/*` **must stay open** — the OIDC flow and the off-LAN app login path.
Do **not** block generic `/Users`: it breaks the API. LAN/tailnet `:443` is a separate site block
and is unaffected.

### 7. Open the front door (only after step 6)

Add `jellyfin.example.com` to the VPS SNI allowlist `map` in
`stacks/micro-vps-ingress/docker-compose.yml` (bump `config-rev`), give it a public `:8443` site
block that does not import `lan_only`, and move it to `PUBLIC_HOSTS` in `edge-access-policy.yml` —
see [network.md → Access control](../../network.md#access-control-who-can-reach-each-subdomain).

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
- **Real client IP in logs** (review decision 2): trigger a login from off-LAN and confirm
  Authentik logs show your actual public IP, not `100.64.0.12`. If it still shows the VPS IP, the
  brute-force policy is blind.
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
  **This re-breaks on any proxy change.** `KnownProxies` is Jellyfin config state, not repo state.
  Untrusted proxy means `X-Forwarded-Proto` is dropped, `Request.Scheme` becomes `http`, and the
  plugin builds `http://jellyfin.example.com/sso/OID/redirect/authentik`, which fails the
  provider's `strict` match. Today it is `172.16.33.0/24` + `fdd0:0:0:21::/64`. That subnet is
  Docker-assigned — `proxy_jellyfin` has no explicit `subnet:` in the Caddy compose, so recreating
  the network can move the CIDR and reproduce this.
- **Login block too broad** → don't block `/sso/`; don't block generic `/Users` (breaks the API).
  Match only the auth endpoints + `/Users/Public`, case-insensitively, incl. the `/emby/` alias.
- **Login block too narrow** (the review's #1 finding) → blocking only `AuthenticateByName` leaves
  the by-user-id path `Users/{id}/Authenticate` open, and `/Users/Public` hands out the GUIDs to use
  it. Block all three (step 6) or "public login removed" is false.
- **SNI `config-rev` not bumped** → VPS serves the old allowlist and public Jellyfin is dropped at
  the VPS. Always bump the label.
- **Cloudflare orange-cloud + video** → ToS §2.8 / buffering; keep Jellyfin gray-cloud and rely on
  the Caddy block (decision 4).
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

## Sources (verified 2026-07-11)

- [9p4/jellyfin-plugin-sso README + providers.md](https://github.com/9p4/jellyfin-plugin-sso) —
  manifest URL, OID endpoint/redirect/start URL formats, roles/folder config, "web UI only", "does
  not disable native login", Overseerr/Jellyseerr + native apps unsupported.
- [Jellyfin — Reverse Proxy docs](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/) —
  Known Proxies / Published Server URL, WebSocket requirement, no trusted-header auth.
- [jellyfin/jellyfin #16956 — clients behind external auth gateways](https://github.com/jellyfin/jellyfin/issues/16956)
  and [discussion #16470 — native OIDC for all clients](https://github.com/orgs/jellyfin/discussions/16470) —
  forward-auth breaks native clients/API; no native OIDC.
