> **Public mirror.** A sanitized, read-only copy of a private homelab repo, synced daily.
> Secrets, the encrypted vault, the access policy files and most internal docs are left out; domains,
> public IPs, SSH keys and personal details are replaced with example values, so nothing here deploys
> as-is. A path named in the text but missing here is one of those private files; links to them are
> removed, and links to pull requests do not resolve. A file that starts with "Example only" (the
> Caddyfile, the tailnet policy, the ingress nginx.conf) is a generic stand-in for a private one.

# NAS

This repository is the single source of truth for the home NAS. It contains all service configurations, documentation, and runbooks.

## Quick links

| | |
|---|---|
| **Architecture diagrams** (how it fits together) | [`docs/architecture.md`](docs/architecture.md) |
| **Services overview** | [`docs/services/`](docs/services/) |
| **Network map** (IPs & ports) | `docs/network.md` |
| **Storage layout** | `docs/storage.md` |
| **Scheduled tasks** | `docs/scheduled-tasks.md` |
| **How-to runbooks** | `docs/runbooks/` |
| **Roadmap** (decided, not built) | `docs/roadmap.md` |
| **Service ideas** (shortlist, nothing chosen) | `docs/service-ideas.md` |
| **Architecture review** (2026-09-25) | not published |
| **Docker stacks** | [`stacks/`](stacks/) |

## How stacks work

Stacks are **Komodo Stacks** declared in [`komodo/resources.toml`](komodo/resources.toml). To deploy a change:

1. Edit the relevant `stacks/<name>/docker-compose.yml`
2. Commit and push (image bumps arrive as Renovate PRs, merged by the review sweep)
3. [`deploy-stacks`](.github/workflows/deploy-stacks.yml) deploys every changed stack through Komodo, health-checks it and rolls it back if it comes up unhealthy — see the deploy-stacks runbook

Not deployed that way, applied by hand instead:

- The three Komodo peripheries.
- `komodo` itself.

## Adding a new service

See the new service runbook.

## Replicating this setup

Want to build a NAS like this one from scratch? See the
replicate-setup runbook — the full build order
from TrueNAS install through GitOps, reverse proxy, SSO, and offsite backups.

## AI assistants

If you are an AI assistant working in this repo, read [`AGENTS.md`](AGENTS.md) before making any changes.
