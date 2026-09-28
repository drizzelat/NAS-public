# NAS Agent Instructions

For **all AI assistants** (Claude, GPT, Gemini, Copilot, etc.). Read before any task.

**Behavioral rules go here.** Not in provider-specific files (`CLAUDE.md`, `.cursorrules`, Copilot instructions). Switching providers = zero repo changes.

Provider-specific files (like `CLAUDE.md`) hold only truly provider-specific things: tool config, memory paths, IDE settings. Not task rules.

## What this repo is

Single source of truth for home NAS.

- **`stacks/`** — Docker Compose stacks, deployed as Komodo Stacks. Each subfolder = one stack.
- **`docs/`** — network layout, storage, per-service details, runbooks.
- **`scripts/`** — maintenance/backup helpers, deploy and review logic.

## Critical rule: keep docs in sync

**Change anything → update relevant docs in same response.** No stale docs.

- Add/remove service → update `docs/services/` and `docs/network.md` (ports)
- Change stack → update `docs/services/<name>.md`
- Change network topology → update `docs/network.md`
- Change storage layout → update `docs/storage.md`
- Add runbook/script → add entry in `docs/runbooks/`
- Add/remove stack, or change a traffic, deploy or backup path → update the matching diagram in `docs/architecture.md`

Unsure which docs → update more, not less.

Three of these are **enforced in CI** (`docs-drift` job in `compose-validate.yml`):
every stack needs `docs/services/<name>.md`, every LAN port it publishes needs a
row in the `docs/network.md` ports table, every bind mount needs a row in the
`docs/storage.md` mount table. The same job also requires every Caddyfile vhost to be in
`PUBLIC_HOSTS` or `LAN_ONLY_HOSTS` in `edge-access-policy.yml`, and every `/mnt/data/*` bind
mount to be under `DATA_INCLUDE` in `scripts/cloudsync-chain.sh` or in the backup runbook's
"NOT backed up" table. Check before pushing: `python3 .github/scripts/docs-drift.py`.

Compose conventions are enforced too (`validate` job, [`compose-policy.py`](.github/scripts/compose-policy.py)):
digest pins, `restart:`, no `privileged`, `no-new-privileges` and a memory limit unless exempted there
with a reason, and a `logging:` size cap on every service. Check: `python3 .github/scripts/compose-policy.py`.

**Don't hard-code exact patch versions in prose.** The compose file is the single source of truth for the `tag@sha256` pin. Docs name only the operationally-meaningful level (e.g. *Postgres 18*, *Redis 8*) and point to `stacks/<name>/docker-compose.yml` for the exact version. Renovate bumps compose, never docs, so a patch/minor number written in prose only drifts stale. When you merge a Renovate PR that changes a **major** version (the kind with a migration/runbook), bump that one doc line in `docs/services/<name>.md` in the same merge.

## Navigation

| Question | Where |
| -------- | ----- |
| How does it all fit together? | `docs/architecture.md` — diagrams |
| What services run? | `docs/services/` — one file per service |
| IP / port for X? | `docs/network.md` |
| Where is data stored? | `docs/storage.md` |
| What runs when? | `docs/scheduled-tasks.md` |
| What's planned next, and what's still open? | `docs/roadmap.md` — decided but not built; candidates live in `docs/service-ideas.md` |
| How to do X? | `docs/runbooks/` |
| Stack compose? | `stacks/<name>/docker-compose.yml` |

## Deploying stacks

Komodo deploys every stack listed in [`komodo/owned-stacks`](komodo/owned-stacks), from
`stacks/<name>/docker-compose.yml`, on the Server its `[[stack]]` entry in
[`komodo/resources.toml`](komodo/resources.toml) names. A push to `main` that touches `stacks/**`
runs `deploy-stacks`, which:

- deploys every changed owned stack through Komodo;
- health-checks it and auto-rolls back an unhealthy one;
- creates a new owned stack in Komodo first.

It never tears a stack down. See the [deploy-stacks runbook](docs/runbooks/setup-operations/deploy-stacks.md).

Not deployed that way, applied by hand instead:

- The three `*-periphery` stacks, over SSH.
- `komodo`, deployed only when someone presses Deploy.

**No hard-coded secrets in compose files.** Use `${VAR}` placeholders. Values live in the age vault
(`secrets.enc/stack-env/<stack>.env.age`) and reach Komodo as Variables through
`scripts/secrets.sh push <stack>` — see the [secret-sync runbook](docs/runbooks/setup-operations/secret-sync.md).

## Conventions

- Stack name = folder name under `stacks/`.
- Service docs at `docs/services/<stack-name>.md`.
- LAN-exposed ports listed in `docs/network.md`.
- Docker networks: a web-facing stack joins `proxy_<stack>` (defined in `stacks/caddy`, `external: true` everywhere else); traffic inside a stack stays on its own `default` network. `media_net` is the one cross-stack network — see `docs/network.md`.
- SSH commands use the vault key paths relative to the repo root (`secrets/ssh/<key>`), restored by `scripts/secrets.sh unlock`.
- Timestamps in docs: ISO 8601 (YYYY-MM-DD).

## Comments in YAML and scripts

**Max 2 lines per comment block.** Compose files, workflows and scripts explain
*what is non-obvious about this line*; the long-form reasoning belongs in `docs/`.

- **Don't duplicate the docs.** If a runbook or service doc already explains it,
  cut the comment to one line and link the doc path instead.
- **No incident narratives, no dates, no changelogs.** "Broke on 2026-07-13
  when…" is history — it belongs in the runbook or in git, not in the file.
- **Keep** the one-liner that stops someone breaking the line: a non-obvious
  flag, a `$$` escape, an ordering constraint, a "do not change this" warning.
- **Cut** anything restating what the code says, section-divider banners
  (`# ---- foo ----`), and rationale for a decision already documented.
- Prefer a trailing comment on the line itself over a block above it.

## What NOT to commit

- `.env` files with real secrets
- Private keys or certificates
- Komodo or other API tokens

`.gitignore` excludes these.

**Exception — the encrypted secret vault.** `secrets.enc/` **is** committed: it holds
age *ciphertext* of the per-stack env **and the host SSH keys** (under `secrets.enc/ssh/`), the
public key, and the private key wrapped with your passphrase — all safe by design. Plaintext lives
in the gitignored `secrets/`. Manage it with [`scripts/secrets.sh`](scripts/secrets.sh); see the
[secret-sync runbook](docs/runbooks/setup-operations/secret-sync.md). Never commit the
unwrapped key `secrets/age-key.txt`, any plaintext `.env`, or the plaintext SSH keys under
`secrets/ssh/`.

**Everything on `main` is published, scrubbed.** `public-mirror.yml` syncs a sanitized copy to a
public repo every week, after a Claude review of the diff. Every push to `main` runs its gates. A
new top-level path, public IP, domain or email address fails them: add a `scrub` line for your own
values, or an `allow-*` line for third-party ones, to
[`scripts/public-mirror/rules`](scripts/public-mirror/rules) in the same commit. A new hostname or
person's name passes the gates, so scrub it too. See the
[public-mirror runbook](docs/runbooks/setup-operations/public-mirror.md).

## Committing changes

After any task modifying files, create logical git commits without being asked. Group by concern:

1. **Stack changes** (`stacks/`) — one commit per stack, or combined if multiple added together. `feat(stacks): <desc>` or `fix(stacks/<name>): <desc>`.
2. **Service docs** (`docs/services/`) — commit with or immediately after the stack change they document. `docs(services): <desc>`.
3. **Network / storage docs** (`docs/network.md`, `docs/storage.md`) — separate commit when meaningful new info. `docs: <desc>`.
4. **Security or bug fixes** in compose files — always separate commit, clear message explaining what was wrong.

No mixing stack changes with unrelated doc updates. Prefixes: `feat`, `fix`, `docs`, `chore`.

## Off-NAS hosts (Oracle Cloud)

- **Micro VPS** — the public front door. The NAS sits behind CGNAT; this VPS holds the public IP and
  its nginx stream-forwards `:80/:443` to Caddy on the NAS **over Tailscale**, with no TLS
  termination. SSH: `ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10`. Everything
  else: [`docs/services/micro-vps-ingress.md`](docs/services/micro-vps-ingress.md).
- **Ampere A1** — Matrix, the external Uptime Kuma, Tor bridges, NTP. SSH:
  `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20` (the public IP, not the tailnet
  one). [`docs/network.md`](docs/network.md) → Cloud hosts.

On both, `ubuntu` has passwordless `sudo` and is not in the `docker` group: use `sudo docker`.

## Adding new stack

Full checklist: [new-service runbook](docs/runbooks/setup-operations/new-service.md).

1. Create `stacks/<name>/docker-compose.yml`
2. Create `docs/services/<name>.md` from template at `docs/services/_template.md`, and a row in `docs/services/README.md`
3. Add LAN-exposed ports to `docs/network.md`, host bind mounts to the mount table in `docs/storage.md`
4. Web-facing: `proxy_<name>` in `stacks/caddy/docker-compose.yml`, a vhost in `stacks/caddy/Caddyfile`, the hostname in `.github/workflows/edge-access-policy.yml` and `docs/network.md` → Access control ([network.md → Adding a New Stack](docs/network.md#adding-a-new-stack))
5. A `[[stack]]` entry in `komodo/resources.toml` (`project_name` written out), the name in `komodo/owned-stacks` and in the `reconcile-owned` pattern
6. Env in the vault? `scripts/secrets.sh edit <name>`, then `scripts/secrets.sh komodo-vars <name>` **before merging** (CI holds no vault key). Merging then creates the Komodo Stack and deploys it
7. Commit: `feat(stacks): add <name>`

## Removing stack

1. Delete `stacks/<name>/`, its `komodo/resources.toml` entry, its `owned-stacks` line and its `reconcile-owned` pattern entry. CI tears nothing down: destroy and delete the Komodo Stack by hand afterwards ([deploy-stacks runbook → Removing a stack](docs/runbooks/setup-operations/deploy-stacks.md#removing-a-stack))
2. Delete `docs/services/<name>.md` and its row in `docs/services/README.md`. Git history is the record; no archive copy
3. Remove its ports from `docs/network.md`, its bind mounts from `docs/storage.md`
4. Web-facing: remove its `proxy_<name>` network and vhost from `stacks/caddy/`, and its hostname from `edge-access-policy.yml` and `docs/network.md`
5. Commit: `feat(stacks): remove <name>`
