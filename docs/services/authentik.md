# Service: Authentik

## Overview

Authentik is an identity provider (IdP) and SSO platform. It handles authentication for services that support OAuth2/OIDC or LDAP, and can also front an app that has no login of its own with a proxy provider.

## Stack

- **Stack folder:** `stacks/authentik/`
- **Compose file:** `stacks/authentik/docker-compose.yml`
- **Deploy:** Komodo Stack `authentik` on Server `nas`, adopted 2026-09-15 ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)). A push to its
  folder deploys it through Komodo.

## Access

| Field      | Value                                                    |
| ---------- | -------------------------------------------------------- |
| URL        | `https://auth.example.com`                             |
| Port       | 9000/9443 (container, internal) — no host port published; reached via Caddy over the `proxy_authentik` network |
| Auth       | Local admin user (initial setup via `/if/flow/initial-setup/`) |

## Volumes / data

| Container path | Host path                          | Purpose                    |
| -------------- | ---------------------------------- | -------------------------- |
| `/var/lib/postgresql` | `/mnt/apps/authentik/db` | Postgres database (PG18 versioned datadir; data under `db/18/docker`) |
| `/media`       | `/mnt/apps/authentik/media`        | Uploaded media/icons       |
| `/templates`   | `/mnt/apps/authentik/custom-templates` | Custom flow templates  |
| `/certs`       | `/mnt/apps/authentik/certs`        | TLS certificates           |
| `/blueprints/nas` (worker only, `ro`) | `/mnt/apps/komodo/repos/nas/stacks/authentik/blueprints` | Blueprints from Komodo's clone on the NAS — see [Configuration in git](#configuration-in-git-blueprints) |

## Environment variables

Kept in the vault (`scripts/secrets.sh edit authentik`); `scripts/secrets.sh push authentik` writes them to the Komodo Variables `AUTHENTIK__<KEY>` and deploys the stack through Komodo. Do not put secret values in the compose file.

| Variable              | Description                                              |
| --------------------- | -------------------------------------------------------- |
| `PG_PASS`             | PostgreSQL password (shared by server, worker, and db)   |
| `POSTGRES_USER`       | DB username (default: `authentik`)                       |
| `POSTGRES_DB`         | DB name (default: `authentik`)                           |
| `AUTHENTIK_SECRET_KEY`| Random secret key — generate once, never change          |

> No `AUTHENTIK_TAG` / `COMPOSE_PORT_HTTP` / `COMPOSE_PORT_HTTPS` env vars: the image tag is
> hard-pinned in compose (a fixed digest conflicts with a templated tag), and Authentik publishes
> **no host port** — Caddy proxies to it over `proxy_authentik`, so there is no 9000/9443 host
> binding to conflict with anything else.

## Dependencies

- Internal PostgreSQL container (`postgresql`)
- Docker network `authentik_net` (defined in the stack)

## Notes

- **Provider and application config is in git**, not click-ops — see
  [Configuration in git](#configuration-in-git-blueprints). A UI edit to a blueprinted field is
  reverted on the next apply.
- **No host port**: Authentik's server listens on 9000/9443 *inside* the container only; Caddy reaches it over the `proxy_authentik` network. Nothing is published on the host, so there is no host-port clash to manage.
- **Prometheus metrics are scraped from `server:9300`** by the observability stack, over
  `proxy_authentik`. Nothing here configures it — Authentik exposes `:9300` by default, and
  `victoriametrics` joins the network to reach it. The *Authentik — Identity* dashboard is built on
  it. The **worker's** `:9300` is *not* scraped: it only listens on `authentik_net`, which the
  metrics store deliberately does not join because Postgres is on it. See
  [observability.md](observability.md).
- PostgreSQL is **Postgres 18** (`*-alpine`), pinned `tag@sha256:…` in the compose file so an unreviewed bump can't break the DB schema. Migrated 16→18 on 2026-07-02 (versioned datadir) — see [postgres-major-upgrade runbook](../runbooks/setup-operations/postgres-major-upgrade.md).
- The worker runs **without** the Docker socket or root — only the embedded outpost is used (no
  Docker-type outpost needs host Docker access). If a Docker outpost is added later, harden via a
  socket proxy instead of remounting the raw socket — see
  [authentik-socket-hardening runbook](../runbooks/setup-operations/authentik-socket-hardening.md).

## Configuration in git (blueprints)

**The repo is the source of truth for the objects listed below.** Authentik applies YAML
"blueprints" from a `/blueprints` mount at boot and on a schedule; the files live in
[`stacks/authentik/blueprints/`](../../stacks/authentik/blueprints/) and reach the NAS through
Komodo's clone at `/mnt/apps/komodo/repos/nas`. A blueprint change is a change to this stack's folder,
so `deploy-stacks` deploys `authentik`, which pulls the clone. The Stack's `post_deploy` then fails the
deploy unless the worker sees exactly the clone's files, because a fresh clone would strand the mount
(komodo-migration.md F28). Until 2026-09-17 the files came from the 15-minute pull of
`/mnt/apps/scripts/nas` instead. Closes step 1 of
[GAP-1](../architecture-review-2026-08-20.md#gap-1--npm-and-authentik-config-is-click-ops).

### What is in git

| File | Objects |
| ---- | ------- |
| `files.yaml` | OAuth2 provider `files`, application `files` — see [files](files.md) |
| `jellyfin.yaml` | OAuth2 provider `Jellyfin`, application `jellyfin` |
| `immich.yaml` | OAuth2 provider `Immich`, application `immich` |
| `mealie.yaml` | OAuth2 provider `mealie`, application `mealie` |
| `matrix.yaml` | OAuth2 provider `Matrix`, application `matrix` |
| `access.yaml` | Group `nas-users` **and its membership**, plus the policy binding that gates each of the five applications — see [Application access](#application-access-the-login-allowlist) |

### What is still UI-only

Everything else, and some of it is load-bearing:

- **`client_secret` of every OAuth2 provider.** Deliberate — it must not be in git. Blueprint
  entries omit the field, and an omitted field is left untouched (see *How it applies*), so the
  secrets stay DB state. `client_id` **is** in git; it is a public identifier, not a credential.
  The consequence: restoring from blueprints alone gives you providers whose secrets do not match
  what the consuming service holds. Real recovery is the Postgres dump
  ([postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md)); blueprints restore shape,
  not credentials.
- **Flows, stages, prompts, policies and property mappings.** All of them are still authentik's own
  defaults, applied by the 31 built-in blueprints shipped inside the image under `/blueprints/{default,system,migrations}`.
  Nothing here overrides them, and nothing should: duplicating an upstream blueprint into this repo
  means owning a fork of it across every version bump.
- **Users, tokens and TOTP devices.** Identity data, not configuration. **Groups are the
  exception**: `access.yaml` owns `nas-users` *and* who is in it, because the bindings that gate
  every application are worth exactly as much as that list —
  [Application access](#application-access-the-login-allowlist).
- **Certificates** (`authentik Self-signed Certificate`, the internal JWT certificate) — private key
  material.
- **The brand** (default flows, branding) and the `Local Docker connection` service connection.

### Application access (the login allowlist)

Every application carries one **policy binding** to the group `nas-users`, declared in
`access.yaml`. An Authentik account that is not a member cannot authorize any of them — the
authorization flow denies before the app is ever reached.

| | |
| --- | --- |
| Group | `nas-users` (not a superuser group) |
| Members | `stefan`, `diana` — the household. Declared in `access.yaml`, so git is the allowlist |
| Bound applications | `files`, `immich`, `jellyfin`, `mealie`, `matrix` — all five |
| Deliberately excluded | `akadmin` (bootstrap account, has never logged in) and `admin` (a stale duplicate of `stefan`, last login 2026-05-21). Both still administer Authentik itself; neither can reach an application |

Until 2026-09-16 **no application had a binding at all**, so every active account could reach
every app. Only household accounts existed, so nothing was actually exposed — but the control that
was supposed to enforce it was absent, and a sixth account would have inherited everything.

- **Adding a person** is one line in `access.yaml`, not a UI click. Their account must exist first
  (`!Find` on a username that does not resolve is `null`, and the whole file then rolls back).
- **Narrowing one app** to a subset — say `files` but not `immich` — means a second group and a
  binding to it, not an edit to this one. All five applications run `policy_engine_mode: any`, so
  a second binding ORs with the first.
- **Membership is overwritten on every apply.** The `users` key is present, and a blueprint field
  that is named is enforced (see *Entries update in place* below), so a UI edit to `nas-users`
  survives only until the next apply.
- **This is not a network-layer wall.** It gates *login*; anonymous routes that need no login —
  immich `/share/`, Mealie's public recipes, `files` share and upload links — are untouched by it,
  by design.

### How it applies, and how it fails

- **The worker consumes blueprints, not the server.** The file watcher starts in
  `after_worker_boot`, and discovery/apply are dramatiq actors. Verified on the running instance:
  the server logs `Task enqueued` for `blueprints_discovery`, the worker logs `Task started` /
  `Task finished`. The mount is therefore on `worker` only.
- **Mounted at `/blueprints/nas`, never at `/blueprints`.** Discovery is recursive, so a subdirectory
  works; mounting over `/blueprints` would shadow the image's own built-in blueprints and take the
  default flows with it.
- **Mounted `:ro`.** Authentik never writes back into the git clone.
- **Applied hourly at minute 8** (`blueprints_discovery` schedule) and immediately on file change via
  the inotify watcher. A merged change is live once `deploy-stacks` has deployed `authentik`, worst
  case the next hourly discovery.
- **A file is all-or-nothing.** `apply()` wraps the whole file in one transaction, and it is preceded
  by `validate()`, which is the same apply inside a transaction that always rolls back. One bad entry
  means the file makes no change at all — it does not half-apply.
- **Entries update in place and are partial.** Each entry is matched by a unique natural key
  (`name` for providers and the outpost, `slug` for applications), and the serializer runs with
  `partial=True`. A field the blueprint names is overwritten; a field it omits is left alone. This is
  what makes a UI edit to a blueprinted field temporary: it survives until the next apply.
- **`!Find` that matches nothing resolves to `null`, silently.** For a required field the entry then
  fails validation and the file rolls back (safe). For an *optional* field — `signing_key` is the one
  that matters here — it would quietly null the field instead. That is the one failure mode in these
  files that is not self-announcing, so verify after any change (below).
- **`state:` is `present` everywhere.** `absent` deletes the object; do not put it in these files.

### Changing something

1. Edit the YAML in `stacks/authentik/blueprints/`, open a PR.
2. Dry-run it against the live instance before merging — this applies for real inside a transaction
   that is always rolled back, so it changes nothing:

   ```sh
   # from the repo root
   ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111 \
     'sudo -n docker exec -i authentik-server-1 ak shell' <<'EOF'
   from authentik.blueprints.v1.importer import Importer
   valid, logs = Importer.from_string(open("/dev/stdin").read()).validate()
   EOF
   ```

   In practice paste the file content into the snippet; the useful form is in
   `scripts/` only if it earns a second use.

   **`validate()` returning `True` is not proof the write landed.** It reports serializer
   validity, and a many-to-many field — `nas-users`' `users` list, the one that can lock
   everyone out — is set after save and shows up in no log line. To *see* the resulting state,
   run the apply inside your own transaction and raise out of it:

   ```python
   from django.db import transaction
   from authentik.blueprints.v1.importer import Importer
   from authentik.core.models import Group
   class Rollback(Exception): pass
   try:
       with transaction.atomic():
           Importer.from_string(src).apply()
           print(sorted(u.username for u in Group.objects.get(name="nas-users").users.all()))
           raise Rollback()
   except Rollback:
       pass
   ```
3. Merge. Wait for the NAS pull, or force it: `sudo /mnt/apps/scripts/git-pull-nas.sh`.
4. Confirm the apply landed: Admin interface → **Customization → Blueprints**, or

   ```sh
   sudo -n docker exec authentik-worker-1 ak shell -c \
     'from authentik.blueprints.models import BlueprintInstance
   [print(b.status, b.path) for b in BlueprintInstance.objects.filter(path__startswith="nas/")]'
   ```
5. Run the [edge access probe](../../.github/workflows/edge-access-policy.yml)
   (`gh workflow run edge-access-policy.yml`) — its Layer 2 job expects every public host to
   answer, so a provider change that stops `files` from booting (OIDC discovery is fatal at its
   startup) shows up there.

### Adding a new object

Export it rather than hand-writing it: `ak export_blueprint` serialises the whole instance, and the
entry you want can be lifted out of it. Two traps in that output:

- **It exports proxy providers twice.** `ProxyProvider` subclasses `OAuth2Provider`, so the dump
  contains both an `authentik_providers_proxy.proxyprovider` entry and an
  `authentik_providers_oauth2.oauth2provider` entry for the same row. Keep the `proxyprovider` one.
  Blueprinting both is how you break a proxy provider.
- **It references everything by UUID**, which is not portable to a rebuilt instance. The files here
  substitute `!Find` on a stable key (flow `slug`, mapping `managed`, certificate `name`) and
  `!KeyOf` for references inside the same file.
- It also contains `client_secret`s, password hashes and private keys. **Never commit the raw
  export.**

## First-time UI setup

Most of what used to be in this list is now [in git](#configuration-in-git-blueprints). What is left
is the part a blueprint cannot do.

1. **Bootstrap admin** — browse to `https://auth.example.com/if/flow/initial-setup/` and set the `akadmin` password. (Only works once, before any admin exists.)
2. **Log in** as `akadmin`, then **Admin interface** (top-right) → set the admin email and timezone.
3. **Embedded outpost** — Applications → Outposts → confirm the built-in `authentik Embedded Outpost` is healthy. **Its provider list is empty since the filebrowser removal on 2026-09-09** — nothing uses forward-auth any more. Keep it healthy anyway: it is the only thing that would carry a future proxy provider, and no blueprint sets its list now.
4. **Create the household users first** — Directory → Users: `stefan` and `diana`. This step moved
   ahead of the blueprints on purpose: `access.yaml` resolves both usernames with `!Find`, and if
   either is missing the file rolls back and **no** application gets its binding.
5. **Let the blueprints apply** — the five providers and applications
   (files, jellyfin, immich, mealie, matrix), plus the `nas-users` group and the five access
   bindings, are created from
   [`stacks/authentik/blueprints/`](../../stacks/authentik/blueprints/). Wait for
   **Customization → Blueprints** to show all six `nas/*.yaml` as *successful*, then check
   Directory → Groups → `nas-users` has both members.
6. **Hand out the client secrets** — blueprints do not carry them. For each OAuth2 provider, open it
   in the UI, copy the **Client ID / Client Secret**, and give them to the consuming service:
   immich ([doc](immich.md)), Mealie as `MEALIE_OIDC_CLIENT_ID`/`MEALIE_OIDC_CLIENT_SECRET`
   ([doc](mealie.md)), files as `FILES_OIDC_CLIENT_ID`/`FILES_OIDC_CLIENT_SECRET`
   ([doc](files.md)), Jellyfin's SSO plugin via `SSO-Auth.xml`
   ([runbook](../runbooks/setup-operations/jellyfin-authentik-sso.md)), Matrix
   ([doc](a1-vps-matrix.md)). On a rebuilt instance the secrets are newly generated and **will not
   match** what those services already hold.
7. **Hardening** — Flows & Stages: review the default password policy, and see the gap below.

> **One thing this list still claims that is not true of the live instance** (the missing policy
> bindings, found the same way on 2026-09-06, were closed on 2026-09-16 by
> [`access.yaml`](#application-access-the-login-allowlist)):
>
> - **Jellyfin MFA is conditional, not mandatory.** The Jellyfin provider has no
>   `authentication_flow` of its own, so it falls through to the brand's `default-authentication-flow`,
>   where the `default-authentication-mfa-validation` stage is gated by the stock
>   "user has a configured authenticator" policy. Every household account does have TOTP enrolled, so
>   MFA is prompted in practice; it is not *required*. This doc previously called it mandatory.
>
> It is a deliberate non-change: a dedicated authentication flow tightens who can log in, which is
> a decision, not a transcription. It is not blocked by the blueprints — it is a natural thing to
> add to `jellyfin.yaml` when decided.

## Operations

> Restart/redeploy go through **Komodo** (Stack `authentik`). Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### Restart / redeploy

- Komodo → Stacks → `authentik` → **Deploy** (or **Restart**).
- Or push to `stacks/authentik/` → the runner deploys it through Komodo ([komodo.md → Adopted stacks](komodo.md#adopted-stacks-phase-2)).

### Upgrade

- Server + worker are hard-pinned to one `ghcr.io/goauthentik/server` `tag@sha256:…` (the `AUTHENTIK_TAG`/`AUTHENTIK_IMAGE` env override was dropped — a fixed digest conflicts with a templated tag); Postgres is a pinned `*-alpine` `tag@sha256:…`. Exact versions live in `stacks/authentik/docker-compose.yml`.
- Renovate opens the PR (server and worker move together in one stack PR). Both images are on the sweep's `MERGE_SKIP_IMAGES`, so it is **merged by hand** — **read the Authentik release notes for breaking changes** first. The worker runs DB migrations on start.
- **Never change `AUTHENTIK_SECRET_KEY`** — it invalidates sessions/tokens.

### Restore from backup

1. Stop the `authentik` stack in Komodo (**Stop**; never **Destroy**, which is a compose down). (SSO for `files` and `immich` will be down until it's back.)
2. Restore `apps/authentik/{db,media,custom-templates,certs}` from a ZFS snapshot of `apps` or from Hetzner.
3. **Preferred DB path:** instead of the raw data dir, load the logical dump into `authentik-postgresql-1` — see [postgres-dump runbook](../runbooks/backup-restore/postgres-dump.md).
4. Start the stack. The blueprints re-apply on boot and put the five providers and applications back
   into their git-declared shape — but **not their client secrets**, which only the dump carries.

### Common failures

- **SSO broken across services** → Authentik is down; files/immich/mealie (OIDC) and **public Jellyfin login** fail. `files` is the worst case: its OIDC discovery runs at startup and a failure is fatal, so it cannot even boot until Authentik is serving. Jellyfin has no public password fallback (blocked at the edge) + Quick Connect needs an SSO'd session, so Authentik down = no public Jellyfin login (LAN/Tailscale still work). Bring Authentik up first.
- **Postgres won't start after upgrade** → major-version mismatch; restore the logical dump into a matching Postgres image.
- **Everyone is locked out of every app at once** → `access.yaml` rolled back, most likely because a
  username in its `nas-users` list no longer resolves. The five bindings and the group are one
  transaction, so the previous state stands; check Customization → Blueprints for `nas/access.yaml`.
- **One person can reach nothing while the other can** → they are not in `nas-users`. Fix it in
  `access.yaml`, not in the UI — a UI edit is reverted on the next apply.
- **A blueprint shows `error` in Customization → Blueprints** → nothing was applied from that file
  (one transaction, rolled back), so the live objects are whatever they were. Read the task logs on
  the worker: `docker logs authentik-worker-1 | grep apply_blueprint`.
- **`files.example.com` stops answering after a blueprint change** → no longer a proxy-provider
  problem: since 2026-09-09 Caddy goes straight to the app and `files` runs OIDC itself. Check the
  `files` OAuth2 provider and that discovery still answers
  (`curl -s https://auth.example.com/application/o/files/.well-known/openid-configuration`) — a
  discovery failure is **fatal at `files` startup**, so the container will be down, not just
  unauthenticated.

## Last updated

2026-09-16 — `access.yaml`: group `nas-users` and a policy binding on all five applications, closing the no-binding gap.

2026-09-15 — adopted by Komodo (Phase 2): deploys through the Komodo Stack, env from Komodo Variables.

2026-09-11
