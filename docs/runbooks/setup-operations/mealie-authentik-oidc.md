# Runbook: Expose Mealie publicly behind Authentik (OIDC)

> **Status: done (2026-07-06).** Steps that name NPM describe the edge at the time; since the
> 2026-09-07 Caddy cutover "public" means a Caddyfile vhost without the `lan_only` snippet
> ([caddy.md](../../services/caddy.md)). Password login was switched off afterwards (decision 4), so
> the local-password check in step 5 no longer applies.

## Why

Mealie was LAN-only. The goal: make recipes reachable from the internet without handing out
VPN/Tailscale access to the whole LAN. Two distinct audiences, handled differently:

- **Household (you + gf)** — log in via Authentik (single sign-on, no separate Mealie password).
- **Friends** — view recipes **anonymously**, no account at all, via Mealie's public household +
  per-recipe **Share** links. Nothing in Authentik is created for them.

So this is a two-person OIDC setup, not a multi-user one — **no Authentik groups needed** (see
decision 5).

## Decisions made (and why)

These were discussed and deliberately chosen over the alternatives — see [mealie.md](../../services/mealie.md) / [authentik.md](../../services/authentik.md) for the resulting config:

1. **Native OIDC, not an Authentik forward-auth wall.** Mealie has built-in OIDC support (same
   family as immich's setup), so Authentik becomes Mealie's actual login — not an extra gate in
   front of Mealie's own login screen (that's the filebrowser pattern, and would mean two logins).
   Trade-off: unlike filebrowser, Authentik isn't a network-layer wall here — it doesn't block
   anonymous requests to Mealie at all. That turned out to be a **feature**, not a gap: Mealie's
   own public/shared-recipe routes (see point 3) stay reachable without any account, because
   nothing in front of Mealie is forcing auth on every request.
2. **`OIDC_AUTO_REDIRECT=false`, not `true`.** `true` would skip Mealie's login page entirely
   (truest "single login" feel), but it has reported redirect-loop bugs upstream and it's
   undocumented whether it would also hijack anonymous visits to a public/shared recipe route
   before Mealie's own public-access check runs. `false` costs one extra click (a "Login with
   authentik" button on Mealie's still-visible login page) in exchange for not risking that.
3. **Anonymous recipe sharing needs no extra config.** Mealie already has two native features for
   this, orthogonal to the OIDC/Authentik setup entirely:
   - Per-recipe **Share** button → link that bypasses all permissions, no account ever.
   - Household marked not-private + recipe marked public → visible on the group home page to
     anyone, no account.

   Neither needed an NPM path exclusion or an Authentik policy change, because of decision 1.
4. **`ALLOW_PASSWORD_LOGIN=false` — Authentik is the only login.** Initially left at the default
   `true` for break-glass; flipped to `false` once OIDC was proven, on request, so Mealie's native
   username/password form is hidden and the login page shows only the "Login with authentik"
   button. Trade-off: no local break-glass — if Authentik is down, nobody can log in; recover by
   setting `ALLOW_PASSWORD_LOGIN=true` (Portainer env override or revert) + redeploy. **Precondition
   before disabling:** the Authentik-linked Mealie account must already be an admin (else the local
   admin is unreachable) — simplest if the Authentik email equals `MEALIE_ADMIN_EMAIL`, so OIDC
   maps into the existing admin account.
5. **No Authentik groups (`OIDC_USER_GROUP`/`OIDC_ADMIN_GROUP` dropped).** An earlier draft created
   `mealie-users`/`mealie-admins` for a "many friends with logins" model. That isn't the reality:
   only you + gf ever log in, and friends are anonymous. Both group vars are optional in Mealie, so
   they're gone — "who may log in" is gated by the **Authentik application binding** (only bound
   accounts start a login), and since the Authentik instance only has the household's accounts, that
   binding *is* the whole allowlist. Admin isn't auto-assigned by a group: the OIDC login links to
   an existing Mealie account by email (`OIDC_USER_CLAIM=email`), so your admin email lands in the
   admin account; the gf's account is promoted once by hand if she needs admin.

## What's done via this repo (already committed)

- `stacks/mealie/docker-compose.yml` — added `OIDC_*` env vars (client id/secret pulled from
  Portainer stack env vars, everything else inline).
- `stacks/micro-vps-ingress/docker-compose.yml` — added `mealie.example.com` to the VPS SNI allowlist
  `map`, bumped `config-rev` (required or the VPS nginx container won't pick up the config change
  — see [micro-vps-ingress.md](../../services/micro-vps-ingress.md) Common failures).
- Docs updated: `mealie.md`, `authentik.md`, `micro-vps-ingress.md`, `npm.md`, `network.md`.

## What's manual (do these in order)

> **Order matters.** Do Authentik first — it yields the client id/secret that steps 2–3 need, and
> the `mealie` stack must **not** be redeployed with OIDC enabled but empty creds against a
> not-yet-existing Authentik app (the `deploy-stacks` runner health-checks each redeploy and
> auto-reverts an unhealthy one). So: Authentik → Portainer env vars → push (deploys mealie +
> micro-vps-ingress together) → NPM flip.

1. **Authentik — create the OIDC provider + application** (UI: `https://auth.example.com`).
   **No groups** — it's a two-person household.
   - Provider (Applications → Providers → Create): type **OAuth2/OpenID Connect**. Redirect URIs
     (strict): `https://mealie.example.com/login` and
     `https://mealie.example.com/login?direct=1`. Pick a signing key. Note the **Client ID** and
     **Client Secret**.
   - Application (Applications → Applications → Create): slug **`mealie`** (must match — Mealie's
     `OIDC_CONFIGURATION_URL` is hardcoded to this slug in the compose file), bind to the provider
     above, and add it to the embedded outpost. Bind the application to you + gf (or leave open to
     all Authentik users — same thing, only the household has accounts). That binding is the login
     allowlist.
2. **Portainer — set Mealie's secret env vars**: `MEALIE_OIDC_CLIENT_ID` /
   `MEALIE_OIDC_CLIENT_SECRET` from step 1, on the `mealie` stack's env vars (not in the repo).
3. **Push the repo commits** → the `deploy-stacks` runner fires the `mealie` + `micro-vps-ingress`
   webhooks (git-pull + redeploy on each) and health-checks them. This is what applies both the
   OIDC config and the VPS SNI allowlist entry. Confirm the VPS picked up the allowlist:

   ```sh
   ssh ubuntu@198.51.100.10 -p 2222 -i ~/.ssh/ssh-key-vps.key
   sudo docker exec micro-vps-ingress-nginx-1 grep mealie /etc/nginx/nginx.conf
   ```

4. **NPM — flip the `mealie` proxy host from LAN-only to public**: Hosts → Proxy Hosts →
   `mealie.example.com` → Access List → switch to the public list (`allow all;`), matching
   `immich`'s.
5. **Verify**:
   - From outside the LAN (e.g. mobile data): `https://mealie.example.com` loads and shows a
     **Login with authentik** button.
   - Log in as your household account → lands in Mealie logged in, no separate Mealie password
     prompt (your admin email links to the existing admin account).
   - Confirm the local-password login (`MEALIE_ADMIN_EMAIL`) still works as break-glass.
   - Test the **Share** link / public-household route from a fully logged-out browser to confirm
     anonymous recipe viewing works — this is the path your friends use.

## Difficulties encountered

- **Portainer env vars set via API, not a redeploy from the workstation.** The env vars
  (`MEALIE_OIDC_CLIENT_ID`/`_SECRET`) were pushed straight onto the git stack with
  `PUT /api/stacks/44/git/redeploy?endpointId=3` (body carries the full `env` array +
  `repositoryGitCredentialID: 1`). First attempt 500'd —
  `authentication required: Repository not found` — because the body sent
  `repositoryAuthentication: true` **without** the credential id; the stack authenticates to the
  private repo via Portainer git-credential **ID 1**, so that field is mandatory. Secrets live in
  the gitignored `secrets/portainer-env/mealie.env` (keys `id` / `secret`), never committed.
- **Could not `git push` from the automation shell.** No credential helper, no GitHub SSH key, and
  the PAT in `secrets/portainer-migrate.config.ps1` (`$GitToken`, 31 chars) is rejected by GitHub
  (`Invalid username or token` — expired/legacy). The push was done from the workstation. *TODO if
  automating end-to-end later: refresh that PAT or add a deploy key.*
- **401 after a successful Authentik login — missing OIDC claims (the real gotcha).** Symptom: you
  authenticate at Authentik, get bounced back to Mealie, and Mealie returns
  `401 Unauthorized` on `/api/auth/oauth/callback`. Mealie log shows the token exchange + userinfo
  fetch both **succeed** (`200`), then:

  ```text
  ERROR [OIDC] Required claims not present in ID token or userinfo endpoint
  ```

  Cause: the Authentik OAuth2 provider had no **email/profile scope mappings**, so `userinfo`
  returned only the bare `openid`/`sub` claim — missing `email` (`OIDC_USER_CLAIM`) and `name`
  (`OIDC_NAME_CLAIM`) that Mealie requires. Fix (Authentik only, no redeploy): provider → Edit →
  **Advanced protocol settings → Scopes** → add `authentik default OAuth Mapping: OpenID`
  **openid + email + profile**; Update; retry. Also confirm the Authentik user actually has an
  email set (Directory → Users), or the claim is absent even with the scope. Diagnosing this from
  the Mealie logs (via Portainer's docker API proxy,
  `/api/endpoints/3/docker/containers/mealie/logs`) was what pinpointed it — the generic 401 in the
  browser gives nothing.

## Last updated

2026-07-06
