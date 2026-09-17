# Runbook: filebrowser → FileBrowser Quantum (`files`)

**Status: done 2026-09-09.** `files.example.com` serves FileBrowser Quantum and the
`filebrowser` stack is gone. `/mnt/apps/filebrowser` is deliberately left on disk.

[filebrowser/filebrowser](https://github.com/filebrowser/filebrowser) was archived on
**2026-09-01** — no further releases, bug fixes or security fixes; the published images stay
online. The replacement is **FileBrowser Quantum**
([gtsteffaniak/filebrowser](https://github.com/gtsteffaniak/filebrowser)), which is the same idea
(a web UI over a plain filesystem) with the three things this NAS needs: native OIDC, share links,
and **upload shares** — a link a guest can drop files into without an account.

Alternatives that were rejected: **Filestash** (OIDC is a paid enterprise plugin; the community
build needs an oauth2-proxy in front) and **Nextcloud** (has both link types, but drags in
Postgres + Redis and turns `smb_share` into an external-storage mount).

The two stacks run **side by side** — the new one at `files-new.example.com` — until the new one
is proven, then `files.example.com` moves over and the old stack is deleted. Nothing is migrated:
both read the same `/mnt/data/smb_share`. The old share links and the old user list are the only
state that is not carried over, and they are cheap to recreate.

## What actually changes

| | old `filebrowser` | new `files` |
| --- | --- | --- |
| Auth | Authentik **proxy provider**: Caddy → outpost → app, identity in `X-authentik-username` | Authentik **OIDC**: Caddy → app, the app runs the flow |
| Public links | outpost `skip_path_regex` holes for `/share/`, `/api/public/`, `/static/` | ordinary unauthenticated routes; no holes |
| Upload links | none | upload shares |
| Config | env vars in compose | `stacks/files/config.yaml`, read from the on-NAS clone |
| Secrets | none | `FILES_OIDC_CLIENT_ID` / `FILES_OIDC_CLIENT_SECRET` |

## The one dangerous ordering rule

Quantum runs OIDC **discovery at startup**, and treats a failure as
`logger.Fatalf("Error validating OIDC auth: …")`. If the Authentik `files` application does not
exist yet, the container exits, `deploy-stacks` fails the health gate, and the auto-rollback
reverts the newest stack commit on `main`.

**So: the blueprint must be live in Authentik before `stacks/files/` is ever pushed.** These are
two separate merges, in this order, with a verification between them.

This also makes Authentik a permanent hard start-order dependency for `files` — after a power
loss, `files` cannot start until Authentik is serving. Noted in
[host-reboot-power-loss](../incident-response/host-reboot-power-loss.md).

## Phase 1 — stand the new service up

### 1. Create the dataset

It must be a **ZFS dataset**, not a directory: the nightly Cloud Sync chain discovers *leaf
datasets*, so a plain directory under `/mnt/apps` would never be backed up
([backup runbook](../backup-restore/backup.md)).

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111
sudo midclt call pool.dataset.create '{"name": "apps/files", "type": "FILESYSTEM"}'
sudo chown 568:568 /mnt/apps/files
sudo chmod 775 /mnt/apps/files
```

`568:568` is the TrueNAS apps user the container runs as. Quantum writes the SQLite DB and the
preview cache here and **fatally exits** if it cannot. Keep the `o+x` bit: the nightly health
check's `paths` verb reports a mode it cannot traverse as *MISSING*, i.e. a failing check.

### 2. Merge the Authentik blueprint — on its own

`stacks/authentik/blueprints/files.yaml` only. The on-NAS clone auto-pulls every 15 min and the
Authentik worker applies blueprints on its own discovery interval, so this is not instant.

Verify before going further — this must return JSON, not a 404 page:

```sh
curl -s https://auth.example.com/application/o/files/.well-known/openid-configuration | jq .issuer
# "https://auth.example.com/application/o/files/"
```

The trailing slash matters: go-oidc compares the discovered `issuer` against `issuerUrl` in
`config.yaml` exactly.

### 3. Hand out the client secret

Authentik generates the client secret; the blueprint deliberately does not carry it. Read it from
the UI (Applications → Providers → **files** → **Client Secret**), or straight off the instance:

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111 \
  "sudo -n docker exec authentik-worker-1 ak shell -c 'from authentik.providers.oauth2.models import OAuth2Provider
print(OAuth2Provider.objects.get(name=\"files\").client_secret)'"
```

Put it in `secrets/portainer-env/files.env` in place of `PASTE_FROM_AUTHENTIK`, then
`scripts/secrets.sh lock`. **`lock` re-encrypts every file** (age uses a fresh ephemeral key each
run), so the working tree comes back with all 32 `.age` files modified — stage only
`secrets.enc/portainer-env/files.env.age` and `git checkout -- secrets.enc/` the rest.

While you are in `ak shell`, confirm `!Find` actually resolved. A miss on an *optional* field is
silent (see [authentik.md](../../services/authentik.md) → How it applies), and `signing_key` is the
one that matters:

```sh
p = OAuth2Provider.objects.get(name="files")
print(p.signing_key, p.sub_mode, [r.url for r in p.redirect_uris])
# Certificate-Key Pair authentik Self-signed Certificate  hashed_user_id  [...]
```

### 4. Merge the rest

`stacks/files/`, the `proxy_files` network in `stacks/caddy/`, the `files-new` vhost, the VPS SNI
allowlist entry, `PUBLIC_HOSTS`, and the docs.

**This merge does not create the stack, and its `deploy-stacks` run goes red on purpose.**
[`fire-webhooks.sh`](../../../scripts/deploy/fire-webhooks.sh) refuses to auto-create any new stack
that has a vault entry — CI holds no age key (SEC-1 step 2), so it would create the stack with
every `${VAR}` empty. It errors with exactly the fix:

```text
::error::'files' is NEW and its env lives in the vault (secrets.enc/portainer-env/files.env.age),
which CI has no key for. Create it from your workstation with 'scripts/secrets.sh push files',
then re-run deploy-stacks to health-check it.
```

`caddy` and `micro-vps-ingress` in the same merge *do* deploy. The health-check step is skipped
(it has no `always()`), so a red run here rolls **nothing** back — but it also means those two go
out unverified until the re-run in step 5.

`scripts/secrets.sh push files` is the fix, and it now works — it was itself broken on Portainer
EE 2.45.0 until the `SourceID` change below, because it sent `repositoryGitCredentialID`, a field
2.45.0 no longer has. The raw call it makes, if you need to do it by hand:

```sh
set -a; . secrets/portainer-api.env; set +a
curl --pinnedpubkey "$PORTAINER_PIN" -kfsS -X POST \
  -H "X-API-Key: $PORTAINER_TOKEN" -H "Content-Type: application/json" \
  "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=3" -d '{
    "name": "files",
    "SourceID": 1,
    "repositoryReferenceName": "refs/heads/main",
    "composeFile": "stacks/files/docker-compose.yml",
    "env": [{"name":"FILES_OIDC_CLIENT_ID","value":"…"},
            {"name":"FILES_OIDC_CLIENT_SECRET","value":"…"}],
    "autoUpdate": {"webhook": "<a fresh uuid>"}
  }'
```

Then health-check it:

```sh
gh workflow run deploy-stacks.yml -f stacks=files -f reconcile=false
```

> **`SourceID` is how 2.45.0 does git credentials.** The stack-create payload
> ([`create_compose_stack.go`](https://github.com/portainer/portainer/blob/develop/api/http/handler/stacks/create_compose_stack.go))
> now marks `RepositoryURL`, `RepositoryAuthentication`, `RepositoryUsername`, `RepositoryPassword`
> and `TLSSkipVerify` **deprecated in favour of `SourceID`**, and `RepositoryGitCredentialID` is
> gone from the struct entirely — which is why passing it in any casing changed nothing. Validation
> is skipped wholesale when `SourceID != 0`:
>
> ```go
> if payload.SourceID == 0 {
>     if payload.RepositoryAuthentication && len(payload.RepositoryPassword) == 0 {
>         return errors.New("Invalid repository credentials. Password must be specified when authentication is enabled")
>     }
> }
> ```
>
> List the sources at **`GET /api/gitops/sources`** (not `/api/sources`, which 404s). This estate
> has exactly one, and every stack already uses it:
>
> ```json
> [{"id":1,"name":"NAS","type":"git","url":"https://github.com/drizzelat/NAS",
>   "status":"healthy","provider":"custom","usedBy":24,"environments":3}]
> ```
>
> **Both scripts now send `SourceID`** — `scripts/secrets.sh` and
> `scripts/deploy/fire-webhooks.sh` resolve it from `/api/gitops/sources`, matching on the repo URL
> with any `.git` suffix normalised away (`REPO_URL` carries one, the Source does not) and falling
> back to the single git Source. `PORTAINER_GIT_CREDENTIAL_ID` is no longer read by anything; the
> repo variable was deleted 2026-09-09. Their *redeploy* paths were never broken — see below.

**Deploy order within one merge is `sort -u`, i.e. alphabetical.** Here that is
`caddy` → `files` → `micro-vps-ingress`, so `proxy_files` exists before `files` wants it. That is
luck, not design: a stack sorting *before* the caddy change that consumed a caddy-defined network
would fail its first deploy with `network proxy_x declared as external, but could not be found`.
Deploy the caddy change on its own if you ever hit that.

**The Caddyfile is not part of the caddy stack's deploy.** It comes from the on-NAS clone, which
pulls on a 15-min cron, so a deploy fired the instant a PR merges reloads caddy against the *old*
file. Force it and reload:

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111 \
  'sudo -n /bin/sh /mnt/apps/scripts/git-pull-nas.sh
   sudo -n docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile'
```

### 5. Nothing to do for the webhook

There is no `PORTAINER_WEBHOOKS` secret any more — `deploy-stacks` reads the stack → webhook map
live from `GET /api/stacks`, so the `autoUpdate.webhook` set at create time is already enough.
(`new-service.md` step 7 still says otherwise; it is stale.)

### 6. Verify

- [ ] `docker logs files` shows `OIDC Auth configured successfully` and `Sources: smb_share: …`
- [ ] `https://files-new.example.com` redirects straight to Authentik, no password form
- [ ] Log in; the user appears under Settings → Users
- [ ] Add yourself to the Authentik group **`nas-files-admins`**, log in again, admin UI appears
- [ ] Files under `/mnt/data/smb_share` are listed, and a test upload lands with the right owner
- [ ] **Share link**: share a file with an expiry + password → opens in a private window
- [ ] **Upload link**: upload-share a folder → a logged-out browser can drop a file in it
- [ ] The dropped file appears on the SMB share with owner `568`
- [ ] Both old and new UIs still work — the old stack is untouched at this point

Leave it running for a few days of real use before phase 2.

## Phase 2 — cut over and remove the old stack

Only once phase 1's checklist is green.

### 1. Point the name at the new stack — done 2026-09-09

- `stacks/files/config.yaml` — `server.externalUrl` → `https://files.example.com`.
  **Existing share links break here**: they carry the old host. Recreate any that matter.
- `stacks/caddy/Caddyfile` — delete the `files-new` vhost; split the combined
  `files.example.com, auth.example.com` block so that `auth` keeps going to
  `https://authentik-server-1:9443` and `files` goes to `http://files:30052`.
  Header comment above it goes back to `(5 vhosts, 5 names)`.
- `stacks/authentik/blueprints/files.yaml` — drop the `files-new` redirect URI. The
  `files.example.com` callback was in the provider from day one, so the cutover needs no
  Authentik change to *work* — this is only tidying.
- `stacks/micro-vps-ingress/` — drop the `files-new` map line, bump `config-rev`.
- `.github/workflows/edge-access-policy.yml` — drop `files-new` from `PUBLIC_HOSTS`.

**Two of those files are read from the on-NAS clone, not from the stack deploy** — the Caddyfile
and `config.yaml`. The clone pulls on a 15-min cron, so a deploy fired by the merge reloads caddy
against the *old* Caddyfile and restarts `files` against the *old* `externalUrl`. Force it:

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.178.111 \
  'sudo -n /bin/sh /mnt/apps/scripts/git-pull-nas.sh
   sudo -n docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile'
```

then restart the `files` stack in Portainer so it re-reads `config.yaml`.

Merge this, then confirm `https://files.example.com` reaches the new app and a **fresh** share
link works, before touching anything below.

#### Admin without a per-service group

The original plan had an `adminGroup: nas-files-admins`. That group was never created, so nobody
was ever an admin. It is now **`authentik Admins`**, the group that already exists — one admin
list for the estate, and it matches how the household actually works.

The mechanism matters, because the two settings behave differently
([`backend/http/oidc.go`](https://github.com/gtsteffaniak/filebrowser/blob/v1.5.6-stable/backend/http/oidc.go)):

```go
isAdmin := false
if oidcCfg.AdminGroup != "" {
    if slices.Contains(groups, oidcCfg.AdminGroup) { isAdmin = true }
}
// ... on auto-create only:
if oidcCfg.AdminGroup == "" { isAdmin = config.UserDefaults.Permissions.Admin }
// ... on an existing user:
if isAdmin != user.Permissions.Admin && oidcCfg.AdminGroup != "" { /* update */ }
```

- With `adminGroup` **set**, admin is re-evaluated on every login, so an already-provisioned user
  is promoted (or demoted) without touching the DB.
- With `adminGroup` **empty**, `userDefaults.permissions.admin` applies **only at user creation**,
  and never again. An existing user cannot be promoted that way — and the users DB is
  storm/bbolt (`/state/database.db`), not the SQLite that holds the index, so there is no
  sqlite-CLI escape hatch either. `filebrowser set -u` refuses an OIDC user outright:
  `user %s is not allowed to login with password authentication`.
- It would also have made **every** household member an admin: neither the `files` nor the
  `filebrowser` Authentik application has a policy binding, so every active Authentik user can
  log in.

### 2. Remove the old stack — done 2026-09-09

- Delete `stacks/filebrowser/` and `stacks/authentik/blueprints/filebrowser.yaml`.
- **Drop `proxy_filebrowser` from two stacks, not one.** `stacks/caddy/` defines it (count comment
  18 → 17) and `stacks/authentik/` joins it as `external: true` — the outpost reached
  `filebrowser:30051` over it. Leaving the authentik entry behind would fail its next deploy with
  `network proxy_filebrowser declared as external, but could not be found` once nothing defines it.
  Docker keeps the network itself as an orphan; prune it on the host.
- `.github/workflows/deploy-portainer-app.yml` — `CANARY_STACK` defaulted to `filebrowser`.
  **Point it at `files`** (or set the `PORTAINER_CANARY_STACK` repo variable) or the weekly
  Portainer redeploy-API canary starts failing against a stack that no longer exists. There is no
  `PORTAINER_CANARY_STACK` variable set, so the default is what runs.
- Docs: **archive** `docs/services/filebrowser.md` to `docs/archive/` rather than deleting it
  (`AGENTS.md` → Removing stack, and the `npm` precedent) — a dozen historical runbooks link to it,
  and its same-directory links need repointing to `../services/`. Then the row in
  `docs/services/README.md`, and the references in `docs/services/caddy.md`,
  `docs/services/authentik.md`, `docs/network.md`, `docs/scheduled-tasks.md`, `docs/storage.md`,
  `docs/runbooks/incident-response/host-reboot-power-loss.md`,
  `docs/runbooks/setup-operations/portainer-app-deploy.md`,
  `docs/runbooks/setup-operations/kuma-monitors.md` and
  `docs/runbooks/setup-operations/portainer-webhook-deploy.md`. Migration records
  (`caddy-migration.md`, `komodo-migration.md`, `replicate-setup.md`, …) are history — leave them.
- **Portainer removes the stack by itself.** `fire-webhooks.sh` pass 1 treats a `stacks/<name>/`
  folder that is gone from the repo as a deletion and issues `DELETE /api/stacks/{id}`, before
  pass 2 redeploys anything. That ordering is what makes the network drop safe.
- Authentik → delete the `Filebrowser` application and proxy provider **by hand**. Deleting the
  blueprint file does not delete the objects it created, and the proxy provider stays on the
  embedded outpost's list until it does. `filebrowser.yaml` was the only blueprint that set the
  embedded outpost's `providers` list, so afterwards the outpost serves nothing — expected, since
  no service uses forward-auth any more.

### 3. Leave the old data alone for now

`/mnt/apps/filebrowser` (172K — config + the old SQLite DB) is the only rollback material left
once the stack is gone. Destroy `apps/filebrowser` **only** after a full backup cycle has run with
the new stack in place, and never in the same change as the cutover.

## Rollback

- **Phase 1** — delete the `files` stack in Portainer and revert the merge. `filebrowser` was
  never touched, so there is nothing to restore.
- **Phase 2, before the old stack is deleted** — revert the cutover commit. `files.example.com`
  goes back to the outpost and the old app, which is still running.
- **Phase 2, after the old stack is deleted** — re-add `stacks/filebrowser/` and its blueprint
  from git history, restore `/mnt/apps/filebrowser` if it was destroyed, and recreate the
  Authentik proxy provider from the blueprint.
- **Locked out of `files` entirely** (Authentik broken, no other way in) — same break-glass shape
  as [mealie](../../services/mealie.md), in two steps because the DB already has OIDC users and so
  no admin is auto-created:

  1. Set `auth.methods.password.enabled: true` in `stacks/files/config.yaml`, push, wait for the
     on-NAS clone to pull (≤15 min), restart the stack.
  2. Portainer → `files` → Console, then mint a local admin:

     ```sh
     filebrowser set -u breakglass,<password> -a -c /config/config.yaml
     ```

  Turn password auth back off once Authentik is fixed, and delete that user.
