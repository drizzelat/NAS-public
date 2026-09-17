> **Public mirror.** A sanitized, read-only copy of a private homelab repo, synced on every push.
> Secrets, the encrypted vault and some internal docs are left out; domains, public IPs, SSH keys
> and personal details are replaced with example values, so nothing here deploys as-is.
> Links to pull requests and removed files do not resolve.

# NAS

This repository is the single source of truth for the home NAS. It contains all service configurations, documentation, and runbooks.

## Quick links

| | |
|---|---|
| **Architecture diagrams** (how it fits together) | [`docs/architecture.md`](docs/architecture.md) |
| **Services overview** | [`docs/services/`](docs/services/) |
| **Network map** (IPs & ports) | [`docs/network.md`](docs/network.md) |
| **Storage layout** | [`docs/storage.md`](docs/storage.md) |
| **Scheduled tasks** | [`docs/scheduled-tasks.md`](docs/scheduled-tasks.md) |
| **How-to runbooks** | [`docs/runbooks/`](docs/runbooks/) |
| **Docker stacks** | [`stacks/`](stacks/) |
| **Architecture review** (2026-08-20) | [`docs/architecture-review-2026-08-20.md`](docs/architecture-review-2026-08-20.md) |

## How stacks work

Stacks are **Komodo Stacks** declared in [`komodo/resources.toml`](komodo/resources.toml). To deploy a change:

1. Edit the relevant `stacks/<name>/docker-compose.yml`
2. Commit and push (image bumps arrive as Renovate PRs, merged by the review sweep)
3. [`deploy-stacks`](.github/workflows/deploy-stacks.yml) deploys every changed stack through Komodo, health-checks it and rolls it back if it comes up unhealthy — see the [deploy-stacks runbook](docs/runbooks/setup-operations/deploy-stacks.md)

Not deployed that way, applied by hand instead:

- The three Komodo peripheries.
- `komodo` itself.

## Adding a new service

See the [new service runbook](docs/runbooks/setup-operations/new-service.md).

## Replicating this setup

Want to build a NAS like this one from scratch? See the
[replicate-setup runbook](docs/runbooks/setup-operations/replicate-setup.md) — the full build order
from TrueNAS install through GitOps, reverse proxy, SSO, and offsite backups.

## AI assistants

If you are an AI assistant working in this repo, read [`AGENTS.md`](AGENTS.md) before making any changes.
