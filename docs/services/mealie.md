# Service: Mealie

## Overview

Mealie is a self-hosted recipe manager and meal planner. It imports recipes from
a URL, organizes them with tags/categories, plans meals on a calendar, and
generates shopping lists. Mobile-friendly UI with a REST API.

## Stack

- **Stack folder:** `stacks/mealie/`
- **Compose file:** `stacks/mealie/docker-compose.yml`
- **Deploy:** Komodo Stack `mealie` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field | Value                                                               |
| ----- | ------------------------------------------------------------------- |
| URL   | `https://mealie.example.com`                                      |
| Port  | 9000 (container, not published)                                     |
| Auth  | Authentik OIDC (native connector); local password login as fallback |

**Public** — exposed to the internet (VPS SNI allowlist + a Caddy vhost without the `lan_only` snippet) so friends can log in
via Authentik without VPN access. No host port published — only reachable through the reverse
proxy (no direct-IP bypass). See [authentik](authentik.md) for the OIDC provider setup and
[network.md](../network.md) for the access-control model.

Anonymous recipe sharing (the per-recipe **Share** button, or a public household + public
recipes) is unaffected by this — Mealie's OIDC login only gates its own login page, it isn't a
network-layer wall in front of the app, so those routes stay reachable without any account.

## Volumes / data

| Container path             | Host path               | Purpose                    |
| -------------------------- | ----------------------- | -------------------------- |
| `/app/data`                | `/mnt/apps/mealie/data` | Recipes, uploaded images   |
| `/var/lib/postgresql`      | `/mnt/apps/mealie/db`   | Postgres database (PG18 versioned datadir; data under `db/18/docker`) |

Both on the `apps` NVMe pool — covered by the recursive `apps` ZFS snapshot (every 4h)
and the nightly Hetzner push.

## Environment variables

Kept in the vault (`scripts/secrets.sh edit mealie`); `scripts/secrets.sh push mealie` writes them to the Komodo Variables `MEALIE__<KEY>` and deploys the stack through Komodo (no secret values in the repo):

| Variable                    | Description                                                   |
| --------------------------- | ------------------------------------------------------------- |
| `MEALIE_DB_PW`              | Password for the Mealie Postgres DB (`db` + app, must match)  |
| `MEALIE_ADMIN_EMAIL`        | Email for the auto-created first admin user (`DEFAULT_EMAIL`) |
| `MEALIE_OIDC_CLIENT_ID`     | Authentik OIDC provider client ID (`mealie` application)      |
| `MEALIE_OIDC_CLIENT_SECRET` | Authentik OIDC provider client secret                         |

`BASE_URL`, `DB_ENGINE=postgres`, `POSTGRES_*`, `TZ`, `LANG=de-DE`, and `ALLOW_SIGNUP=false`
are set directly in the compose file. `BASE_URL` must match the proxied URL
(`https://mealie.example.com`) or auth/image links break. `LANG` sets the default UI
language (German); each user can still override it in their own settings.

OIDC (`OIDC_AUTH_ENABLED`, `OIDC_PROVIDER_NAME`, `OIDC_CONFIGURATION_URL`, `OIDC_AUTO_REDIRECT`,
`OIDC_REMEMBER_ME`, `OIDC_REQUIRES_EMAIL_VERIFICATION`) and `ALLOW_PASSWORD_LOGIN=false` are also
set directly in the compose file —
only the client id/secret are runtime secrets. No `OIDC_USER_GROUP`/`OIDC_ADMIN_GROUP`: it's a
two-person household, so access is gated by the Authentik application binding — the `nas-users`
group, see [authentik.md → Application access](authentik.md#application-access-the-login-allowlist)
— not a Mealie group.
`ALLOW_PASSWORD_LOGIN=false` makes **Authentik the only login** (the native username/password form
is hidden) — see the break-glass note under First-time UI setup. See First-time UI setup below.

`OIDC_REQUIRES_EMAIL_VERIFICATION=false` is **required with this Authentik setup**, not a
preference: Mealie v3.21+ refuses any OIDC login unless the IdP asserts `email_verified`, and
Authentik's default `OpenID 'email'` scope mapping hardcodes `email_verified: False` (its
`blueprints/system/providers-oauth2.yaml`, still true in 2026.5.6). Leaving it at Mealie's default
`true` locks everyone out, admin included, because `ALLOW_PASSWORD_LOGIN=false` leaves no fallback.
The check exists to stop an unverified self-asserted email from matching an existing account —
no risk here (two hand-created Authentik accounts, no self-registration). Alternative, if the
check is ever wanted back: give the `mealie` provider a **custom** scope mapping named `email`
that returns `email_verified: True` — don't edit the default mapping, it's a managed blueprint
object and gets reset on every Authentik upgrade.

## AI recipe parsing (Gemini)

Mealie uses an **OpenAI-compatible** AI provider for smarter recipe parsing: better
ingredient parsing, URL import when the built-in scraper fails, and **video import**
(YouTube/TikTok/IG — Mealie downloads the video, transcribes the audio, then parses the
transcript into a recipe).

Configured **in the UI**, not via env vars: **Settings → AI / Anbieter → Edit provider**
(fields: Model, API-Key, Basis-URL, Timeout). Current setup uses **Google Gemini** via its
OpenAI-compatible endpoint on a **free Google AI Studio API key**.

| Field | Value |
| ----- | ----- |
| Anbietername | `Gemini` |
| Modell | current non-retired Flash model — `gemini-3.1-flash-lite` as of 2026-08-22 |
| Basis-URL | `https://generativelanguage.googleapis.com/v1beta/openai/` |
| API-Key | free key from [aistudio.google.com](https://aistudio.google.com) |
| Timeout | `300` |

> **This key is not in the vault and not in `stacks/`.** Mealie stores it in its own Postgres,
> `ai_providers.api_key` — so it is covered by the nightly `mealie` dump, but grepping the repo
> for it finds nothing. Read the live values with:
>
> ```bash
> docker exec mealie-db psql -U mealie -d mealie -c \
>   'select name, base_url, model from ai_providers;'
> ```
>
> **Do not confuse it with the removed paperless-ai key.** Both hit the same Gemini endpoint, but
> they are two distinct keys in two different Google key formats: Mealie's starts `AIzaSy` (39
> chars) and is **live**; paperless-ai's started `AQ.` (53 chars) and is dead, pending revocation.
> Revoking the wrong one silently breaks URL, image and video import here. See
> [paperless.md](paperless.md#ai-auto-tagging--removed-2026-08-21).

**Why Gemini:** free tier (no card) covers a home recipe library; recipe parsing is a tiny job
per import. Text URL import, image import, and **video/YouTube transcription all confirmed
working** on this free Gemini key (2026-07-10) — no separate OpenAI/Whisper key needed.

**Gotchas (both cause 404s):**

- **Basis-URL must end with a trailing slash** (`/v1beta/openai/`). Without it, the OpenAI
  client joins the path wrong (`.../v1beta/chat/completions`) → 404. The `/openai/` segment is
  also required — the bare `/v1beta` is Google's native API, not the OpenAI-compat dialect Mealie
  speaks.
- **Model name must be current.** `gemini-2.5-flash` and `gemini-2.0-flash` are retired → 404.
  Use whatever Flash model is live in AI Studio.
- **Google AI Pro / Ultra subscriptions do NOT grant API access** — chat product only. Needs a
  separate AI Studio API key (independent, free tier). Same applies to a Claude subscription: use
  an Anthropic API key, not the chat sub.

Free-tier caps apply (per-minute/per-day request limits) — a bulk import of hundreds of recipes
at once can hit the daily cap; spread it out or switch the provider to a paid key for the big batch.

Diagnose from the shell before touching Mealie (`200` = URL/key/model good):

```bash
curl "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" \
  -H "Authorization: Bearer $GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3-flash-preview","messages":[{"role":"user","content":"hi"}]}'
```

## Dependencies

- `mealie-db` (Postgres 18) — runs in the same stack on the `default` network.
- `proxy_mealie` external network — defined by the `caddy` stack, which joins it to reach the app (Hub & Spoke).

## Notes

- Bootstrap login (only before `ALLOW_PASSWORD_LOGIN=false`): user `MEALIE_ADMIN_EMAIL`, default
  password `MyPassword` (Mealie default) — **change it immediately**. See First-time UI setup.
- `ALLOW_SIGNUP=false` keeps registration invite/admin-only. Flip to `"true"` only to allow
  open sign-up.
- Postgres backend chosen over the SQLite default for reliability + the logical dump path.

## First-time UI setup

1. **On first bring-up only** (before OIDC works), log in at `https://mealie.example.com` as
   `MEALIE_ADMIN_EMAIL` (default password `MyPassword`) → **change the password**. Once OIDC is
   proven and you set `ALLOW_PASSWORD_LOGIN=false` (Authentik-only login), this native form is
   hidden — so **before** disabling it, confirm your Authentik-linked account is a Mealie admin
   (Admin → Users), ideally by making your Authentik email equal `MEALIE_ADMIN_EMAIL` so OIDC logs
   you into the existing admin account. Break-glass with password login off: if Authentik is down,
   nobody can log in — recover by flipping `ALLOW_PASSWORD_LOGIN` back to `true` (vault + `secrets.sh push mealie`,
   or revert the commit).
2. Settings → set site name, default language/timezone, first day of week.
3. **OIDC (Authentik)** — create the Authentik OIDC provider + application first (see
   [authentik doc](authentik.md)); no groups needed for a two-person household. Once
   `MEALIE_OIDC_CLIENT_ID`/`MEALIE_OIDC_CLIENT_SECRET` are in the vault and pushed
   (`secrets.sh push mealie`), a **"Login with authentik"** button appears on the Mealie login page
   (`OIDC_AUTO_REDIRECT=false`, so it's one click, not an auto-bounce; with
   `ALLOW_PASSWORD_LOGIN=false` the button is the *only* thing on the page). Test it in a private
   window before relying on it — the OIDC login links to an existing Mealie account by matching
   email (`OIDC_USER_CLAIM=email`), so logging in with the same email as `MEALIE_ADMIN_EMAIL`
   lands you in the admin account; a new email auto-provisions a regular user
   (`OIDC_SIGNUP_ENABLED` defaults `true`) — promote it via Admin → Users if needed (e.g. the gf).
4. **Public/shared recipes for friends** — to let a recipe be viewed with **no login at all**,
   either use the per-recipe **Share** button (generates a link that bypasses all permissions),
   or mark the household as not-private (Admin → Households) and flip individual recipes to
   public. This is how friends get access — they never need an Authentik account.
5. Import a recipe by URL to confirm scraping works end-to-end.

## Operations

> Restart/redeploy go through **Komodo** (Stack `mealie`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `mealie` → **Deploy** (or **Restart**).
- Or push to `stacks/mealie/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- App and `db` (**Postgres 18**) are pinned `tag@sha256:…` (exact versions in the compose file).
  Renovate opens the PRs. The app goes through the review sweep; its **major** bumps are labelled
  `needs-manual-review` (DB migrations), and the v3.21 `email_verified` lockout arrived in a
  *minor*, which is why every bump is reviewed. Postgres is on the sweep's `MERGE_SKIP_IMAGES` and
  is merged by hand.

### Restore from backup

1. Stop the `mealie` stack in Komodo (**Stop**; never **Destroy**, which is a compose down).
2. Restore `apps/mealie/{data,db}` from a ZFS snapshot or from Hetzner.
3. **Preferred DB path:** load the logical dump into `mealie-db` — see [postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md).
4. Start the stack.

> Mealie also has a built-in backup feature (Admin → Site Administration → Backups) that
> bundles recipes + DB into a `.zip` under `/app/data/backups` — independent of the ZFS path.

### Common failures

- **DB auth failure** → `MEALIE_DB_PW` must match between the `db` and app containers.
- **Login/image links wrong host or mixed-content** → `BASE_URL` must equal the proxied URL.
- **502 from Caddy** → confirm `caddy` is attached to `proxy_mealie` (the deploy-state probe asserts it) and the `mealie` container is healthy.
- **"Login with authentik" button missing** → `MEALIE_OIDC_CLIENT_ID`/`MEALIE_OIDC_CLIENT_SECRET`
  not set (vault → Komodo Variables) or `OIDC_AUTH_ENABLED` isn't `"true"`.
- **OIDC login fails / redirects back to Mealie login** → check the Authentik application/provider
  is bound to the embedded outpost and healthy; confirm `OIDC_CONFIGURATION_URL` matches the
  provider's slug (`.../application/o/mealie/.well-known/openid-configuration`); confirm your
  Authentik account is bound to the Mealie application (access is gated there, not by a Mealie
  group).
- **401 Unauthorized on `/api/auth/oauth/callback` after a successful Authentik login** → the
  Mealie log shows `[OIDC] Required claims not present in ID token or userinfo endpoint`. The
  Authentik OAuth2 provider is missing scope mappings, so `userinfo` omits `email`/`name`. Fix in
  Authentik: provider → Advanced protocol settings → **Scopes** = `openid` + `email` + `profile`;
  also ensure the user has an email set. No Mealie redeploy needed. See
  [authentik doc](authentik.md) step 6 and the
  [mealie-authentik-oidc runbook](../runbooks/setup-operations/mealie-authentik-oidc.md).
- **OIDC login refused after a Mealie upgrade, log says `[OIDC] email_verified claim is missing or
  false; refusing to authenticate`** → v3.21+ enforcement plus Authentik's default
  `email_verified: False`. Set `OIDC_REQUIRES_EMAIL_VERIFICATION=false` (compose, or through the vault and
  `secrets.sh push mealie` for an immediate fix) — see Environment variables above. With `ALLOW_PASSWORD_LOGIN=false`
  this is a full lockout, so the break-glass is `ALLOW_PASSWORD_LOGIN=true` + `secrets.sh push mealie`.
- **Public/shared recipe still shows a login wall** → this is a Mealie-side setting, not a
  proxy/Authentik one: check the household isn't private and the recipe is flagged public (or use
  a **Share** link instead, which bypasses permissions regardless of household privacy).
- **AI parsing / video import 404s** → Basis-URL missing the trailing slash or `/openai/`
  segment, or a retired model name (`gemini-2.5-flash`/`2.0-flash`). See AI recipe parsing above.

## Last updated

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
