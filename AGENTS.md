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
`docs/storage.md` mount table. Check before pushing: `python3 .github/scripts/docs-drift.py`.

**Don't hard-code exact patch versions in prose.** The compose file is the single source of truth for the `tag@sha256` pin. Docs name only the operationally-meaningful level (e.g. *Postgres 18*, *Redis 8*) and point to `stacks/<name>/docker-compose.yml` for the exact version. Renovate bumps compose, never docs, so a patch/minor number written in prose only drifts stale. When you merge a Renovate PR that changes a **major** version (the kind with a migration/runbook), bump that one doc line in `docs/services/<name>.md` in the same merge.

## Navigation

| Question | Where |
| -------- | ----- |
| How does it all fit together? | `docs/architecture.md` — diagrams |
| What services run? | `docs/services/` — one file per service |
| IP / port for X? | `docs/network.md` |
| Where is data stored? | `docs/storage.md` |
| What runs when? | `docs/scheduled-tasks.md` |
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
(`secrets.enc/portainer-env/<stack>.env.age`) and reach Komodo as Variables through
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

**Everything on `main` is published, scrubbed.** `public-mirror.yml` pushes a sanitized copy of
every `main` commit to a public repo. A new public IP makes that sync fail. A new domain, hostname,
person's name or SSH key does not, so add a `scrub` line to
[`scripts/public-mirror/rules`](scripts/public-mirror/rules) in the same commit. See the
[public-mirror runbook](docs/runbooks/setup-operations/public-mirror.md).

## Committing changes

After any task modifying files, create logical git commits without being asked. Group by concern:

1. **Stack changes** (`stacks/`) — one commit per stack, or combined if multiple added together. `feat(stacks): <desc>` or `fix(stacks/<name>): <desc>`.
2. **Service docs** (`docs/services/`) — commit with or immediately after the stack change they document. `docs(services): <desc>`.
3. **Network / storage docs** (`docs/network.md`, `docs/storage.md`) — separate commit when meaningful new info. `docs: <desc>`.
4. **Security or bug fixes** in compose files — always separate commit, clear message explaining what was wrong.

No mixing stack changes with unrelated doc updates. Prefixes: `feat`, `fix`, `docs`, `chore`.

## VPS ingress proxy (Oracle Cloud)

Public entry point for the home NAS. NAS sits behind CGNAT/FritzBox with no inbound port forward; this VPS holds the public IP, accepts public 80/443, and forwards raw TCP to the NAS **over Tailscale** (WireGuard mesh). No TLS termination on the VPS — SNI/HTTPS pass through to **Caddy** on the NAS. Public names are orange-clouded at Cloudflare except `jellyfin` (gray-cloud, streaming). Full detail: [`docs/services/micro-vps-ingress.md`](docs/services/micro-vps-ingress.md). The second Oracle host (Ampere A1 — Matrix, external Kuma, Tor bridge) is in [`docs/network.md`](docs/network.md) → Cloud hosts.

> **History:** until 2026-07-01 the backhaul was a [rathole](https://github.com/rapiz1/rathole) reverse tunnel (VPS ran a rathole server on :2333, NAS dialed out with a rathole client). Replaced by Tailscale: fewer moving parts, no shared token, encrypted transport, and the VPS is now a Komodo Server over the tailnet (a Portainer node until 2026-09-17). Until 2026-09-07 the NAS edge was NPMplus; it is now Caddy.

### Access

| Field | Value |
| ----- | ----- |
| SSH host | `198.51.100.10` |
| SSH port | `2222` |
| SSH user | `ubuntu` (passwordless `sudo`) |
| SSH key | `secrets/ssh/ssh-key-vps.key` (age vault; `scripts/secrets.sh unlock`) |
| Connect | `ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10` |

### Host

- Oracle Cloud instance `instance-20260417-1014`, Ubuntu 24.04.4 LTS, kernel `6.17.0-oracle`, `x86_64`.
- 2 vCPU, 954 MiB RAM, **no swap**. 45 GB root disk (`/dev/sda1`, ~8% used).
- Timezone `Etc/UTC`. Public IP = SSH host IP.
- Docker 29.4.0 + Compose v5.1.3; `docker` service enabled at boot. User `ubuntu` **not** in `docker` group → use `sudo docker`.
- Tailscale 1.98 (native pkg, host). VPS tailnet IP `100.64.0.12`, joined with `--accept-routes` (NAS advertises `192.168.178.0/24`). NAS tailnet peer = `nas` `100.64.0.11` (Caddy listens `0.0.0.0:80/443/8443`).

### Data flow

```text
Internet :80/:443   (orange-cloud names arrive from Cloudflare edges)
   -> nginx (stream proxy, host net)
        :80  -> 100.64.0.11:80    (NAS Caddy, over Tailscale)
        :443 -> 100.64.0.11:8443  (SNI + Cloudflare-peer allowlist; PROXY protocol v1)
   -> Tailscale (WireGuard) -> NAS Caddy -> authentik / services
```

nginx does raw TCP stream forwarding. `proxy_pass` targets the NAS **tailnet IP** directly — the WireGuard tunnel is the transport. (Testing `curl https://<tailnet-ip>` with no SNI fails the TLS handshake at Caddy — expected; real clients carry SNI.)

### Stack

- **`nginx` ingress = Komodo Stack** `micro-vps-ingress` on Server `micro-vps`. In this repo at `stacks/micro-vps-ingress/` (`docker-compose.yml` only — the nginx config is an inline `configs:` block, there is no separate `nginx.conf`). Backups under `/home/ubuntu/backups/<ts>/`.
- **`komodo-periphery` = repo + SSH apply, NOT deployed by Komodo.** It is the transport the Stack deploys through, so it must not be torn down by its own deploys. Source of truth [`stacks/micro-vps-periphery/`](stacks/micro-vps-periphery/); see [`docs/services/micro-vps-periphery.md`](docs/services/micro-vps-periphery.md).
- Both `restart: unless-stopped`:
  - `nginx` (`micro-vps-ingress-nginx-1`) — `nginx:alpine`, `network_mode: host`, config from the compose `configs:` block.
  - `komodo-periphery` — host network, listening on the tailnet IP `100.64.0.12:8120` only.
- Reboot survival: `restart: unless-stopped` + `docker` enabled at boot. Manual: **Deploy** the Stack in Komodo; with Core unreachable, `cd /etc/komodo/repos/nas/stacks/micro-vps-ingress && sudo docker compose -p micro-vps-ingress up -d` from the periphery's clone (the break-glass since 2026-09-17).
- Until 2026-09-17 a Portainer agent (`:9001`) and a hand-kept `/home/ubuntu/docker-compose.yml` copy lived here too; both were removed in SVC-2 Phase 3.

### Public ports

| Port | Service | Note |
| ---- | ------- | ---- |
| 2222 | sshd | admin |
| 80 | nginx stream | -> NAS `100.64.0.11:80` via Tailscale |
| 443 | nginx stream | -> NAS `100.64.0.11:8443` (Caddy PROXY-protocol listener) via Tailscale |

`8120` (Komodo periphery) binds the tailnet IP only — not public. `111`/rpcbind masked, `2333`/rathole gone. Firewall = iptables (Oracle default), **no ufw**, **no fail2ban**.

### Known issues / hardening TODO

- Stale iptables ACCEPT for tcp/2333 remains (harmless — nothing listens). Oracle security-list rule for 2333 can also be dropped.
- No fail2ban on SSH (SSH is on non-standard port 2222, key-only).
- Depends on Tailscale on both ends: if the NAS tailnet node or subnet-router drops, public sites go down. The A1 Uptime Kuma probes the public URLs from outside, and healthchecks.io watches this host (guard container `micro-vps-ingress-nginx-1`).

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
2. Archive `docs/services/<name>.md` under `docs/archive/` and move its row in `docs/services/README.md` to Archived
3. Remove its ports from `docs/network.md`, its bind mounts from `docs/storage.md`
4. Web-facing: remove its `proxy_<name>` network and vhost from `stacks/caddy/`, and its hostname from `edge-access-policy.yml` and `docs/network.md`
5. Commit: `feat(stacks): remove <name>`
