# Runbook: Migrate Portainer stacks from web-editor to GitOps

> **Status: done — historical.** Every stack was migrated. Since then polling was switched off in
> favour of webhooks ([portainer-webhook-deploy](portainer-webhook-deploy.md)), new stacks are
> created by `deploy-stacks` or `scripts/secrets.sh push`, and the reverse proxy is Caddy. Read the
> steps below as a record, not a procedure.

Goal: switch every manually-pasted (web-editor) stack in Portainer to a **Git
repository** stack that auto-pulls from `github.com/drizzelat/NAS.git`, **without
losing the environment variables** currently typed into Portainer.

Portainer cannot convert a stack's build method in place, so each stack is
**removed and re-created** from the repo. This is safe for data: stack removal runs
`docker compose down` *without* `-v`, so named volumes and all bind mounts
(`/mnt/apps`, `/mnt/data`) persist. Only brief per-stack downtime.

Tooling: `scripts/portainer-migrate/` (PowerShell, Windows).

## Prerequisites (one-time)

1. **Portainer API token** — Portainer UI → top-right user menu → *My account* →
   *Access tokens* → *Add access token*. Copy it.
2. **GitHub PAT (read-only)** — repo is private, so Portainer needs to clone it.
   - Classic token: scope `repo` (read is enough).
   - Or fine-grained: `Contents: Read-only` on `drizzelat/NAS`.
   - **Preferred:** add it to Portainer's **Git credentials** store (Portainer UI →
     your user → *Git credentials* → *Add*). `extract.ps1` prints the credential ID;
     put it in the config as `$GitCredentialId` so the PAT stays out of the config file.
3. **Config file** — copy the template and fill it in:
   ```powershell
   Copy-Item scripts\portainer-migrate\config.example.ps1 secrets\portainer-migrate.config.ps1
   notepad secrets\portainer-migrate.config.ps1
   ```
   `secrets/` is gitignored — the token never gets committed.

## Phase 1 — Extract (read-only, changes nothing)

```powershell
.\scripts\portainer-migrate\extract.ps1
```

Writes (all gitignored under `secrets/`):

| Output                              | Purpose                                       |
| ----------------------------------- | --------------------------------------------- |
| `portainer-env/<stack>.env`         | env vars currently set in Portainer (backup)  |
| `portainer-compose-live/<stack>.yml`| compose currently deployed                    |
| `portainer-stacks.json`             | stack metadata (ids, AlreadyGit flag)         |

**Then diff** each live compose against the repo file before migrating:

```powershell
foreach ($f in Get-ChildItem secrets\portainer-compose-live\*.yml) {
  $repo = "stacks\$($f.BaseName)\docker-compose.yml"
  if (Test-Path $repo) { Write-Host "== $($f.BaseName) =="; git --no-pager diff --no-index $f.FullName $repo }
}
```

If the repo compose differs from what's running, fix the repo file first — the repo
becomes the source of truth after migration.

## Phase 2 — Migrate (one canary, then the rest)

Dry run a single low-risk stack:

```powershell
.\scripts\portainer-migrate\migrate.ps1 -Stack adguard -WhatIf
```

Do it for real, verify the container is healthy in Portainer, confirm env vars
landed:

```powershell
.\scripts\portainer-migrate\migrate.ps1 -Stack adguard
```

Then migrate everything else:

```powershell
.\scripts\portainer-migrate\migrate.ps1 -All
```

Each migrated stack gets GitOps auto-update at the interval in the config
(`$PollInterval`, default 5m). *(Superseded: polling is now off on every stack.)*

## Verify

```powershell
.\scripts\portainer-migrate\extract.ps1   # AlreadyGit should now be True for all
```

In Portainer each stack should show *This stack was created from a git repository*.

## Notes & gotchas

- **Point the config at the LAN IP, not the domain.** Migrating `adguard` (DNS) and
  `npm` (reverse proxy) briefly takes them down, so `nas.example.com` stops
  resolving/proxying mid-run. Use `$PortainerUrl = 'https://192.168.178.111:31015'`.
  Portainer is published directly on 31015 (not behind npm), so the IP always works.
- **API facts for this Portainer (EE):** create stack = `POST
  /api/stacks/create/standalone/repository?endpointId=<id>`; the compose path field is
  **`composeFile`** (not `composeFilePathInRepository`); git auth preflight =
  `POST /api/gitops/repo/refs`; git credentials live at
  `/api/users/<userId>/gitcredentials`. Endpoint id here is `3` (`local`).
- **`portainer` is skipped** — it runs as a TrueNAS app, not a Portainer stack.
- If a Portainer stack name ≠ repo folder name, pass a mapping:
  `migrate.ps1 -All -FolderMap @{ 'oldname' = 'stacks-folder' }`.
- If recreate fails, the env backups in `secrets/portainer-env/` let you rebuild the
  stack by hand. The old stack is already deleted at that point, so fix the repo file
  / creds and re-run `migrate.ps1 -Stack <name>` (it will just create, since the old
  one is gone).
- Env vars referenced by the composes at the time: `POSTGRES_PW`, `POSTGRES_USER`, `POSTGRES_DB`,
  `PG_PASS`, `REDIS_PW`, `AUTHENTIK_SECRET_KEY`, `BESZEL_ENVIRONMENT_AGENT_KEY`,
  `DISCORD_WEBHOOK_URL`, `GAMEVAULT_DB_PW`, `LIDARR_KEY`, `RADARR_KEY`, `SONARR_KEY`,
  `WG_KEY`.
