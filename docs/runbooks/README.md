# Runbooks

Operational and incident-response procedures for the NAS. Per-service operations
(restart, upgrade, restore, common failures) live in each service's doc under
[`docs/services/`](../services/) → **Operations**; the cross-cutting and setup procedures
are here.

## Incident response (something is broken)

| Runbook | When |
| --- | --- |
| [Host reboot / power loss](incident-response/host-reboot-power-loss.md) | Planned reboot or power cut — bring-up order + per-boot verification |
| [Disaster recovery](incident-response/disaster-recovery.md) | Boot drive / pool / whole box lost — bare-metal rebuild, by scenario |
| [Disk failure / replacement](incident-response/disk-failure-replacement.md) | SMART alert, degraded pool, drive swap + resilver |
| [Cert / DNS / proxy outage](incident-response/cert-dns-proxy-outage.md) | Unreachable by name, TLS errors, "everything's down from the internet" |
| [NAS NIC packet loss](incident-response/nas-nic-packet-loss.md) | Kuma shows lossy or multi-second pings to a healthy NAS — EEE on the Realtek NIC |

## Backup & restore

| Runbook | Covers |
| --- | --- |
| [Off-site backup (Hetzner)](backup-restore/backup.md) | Cloud Sync design, schedule, what's in/out, restore |
| [Postgres logical dumps](backup-restore/postgres-dump.md) | Nightly `pg_dump`, DBs covered, restore |
| [TrueNAS config backup](backup-restore/truenas-config-backup.md) | Config email, what lives in Bitwarden, DR scenarios |
| [Restore drill (quarterly)](backup-restore/restore-drill.md) | Prove the offsite chain by pulling + decrypting a real dataset & pg_dump; silent-failure heartbeats |
| [Backing up the A1](backup-restore/a1-matrix-backup.md) | Synapse + bridge dumps, the media store and the external Kuma's state, pulled to the NAS nightly; rebuilding the A1 from them |

## Setup & operations

| Runbook | Covers |
| --- | --- |
| [Replicate this setup](setup-operations/replicate-setup.md) | Full build order from scratch |
| [NAS repo auto-pull](setup-operations/nas-repo-autopull.md) | Cron scripts run from a live clone kept in sync with `main` (deploy key + pull cron) |
| [Public mirror](setup-operations/public-mirror.md) | Sanitized public copy of `main` for friends: what is left out or scrubbed, the three gates, a failed sync, undoing a leak |
| [Renovate on-time trigger](setup-operations/renovate-trigger.md) | Host cron fires the Renovate run via `workflow_dispatch` (GitHub `schedule:` is late) |
| [Renovate as a GitHub App](setup-operations/renovate-github-app.md) | Repo-scoped App installation token in place of the account-wide classic PAT — App creation clicks, the permission table, cutover and rollback |
| [Renovate PR review](setup-operations/renovate-pr-review.md) | The gate every stack bump passes: registry-API image delta (incl. "no-op for our arch") + a Claude risk verdict, then a 05:00–06:00 sweep that merges only the no-ops and the `RISK: LOW` ones |
| [Tailscale remote access](setup-operations/tailscale-migration.md) | Design & gotchas of the Tailscale path (DNS hairpin, HTTP/2 444, SNAT) |
| [VPS ingress backhaul](setup-operations/vps-tailscale-backhaul.md) | Tailscale backhaul for the public VPS ingress, incl. the LAN-only exposure fix |
| [Provision an Oracle A1 node](setup-operations/a1-provision.md) | Fresh Ampere A1: firewall (both layers), SSH hardening, Docker, Tailscale, add as a Komodo Server — foundation for the Matrix deploy |
| [OS updates](setup-operations/os-updates.md) | Nightly automatic updates and reboots on the micro and A1 (Ubuntu, Docker 29.x point releases), why data volumes must mount by UUID; the NAS's update-available email |
| [Adding a new service](setup-operations/new-service.md) | Stack + docs + ports + backup checklist |
| [RomM game emulation](setup-operations/romm-emulation.md) | Self-hosted ROM library: browser retro (EmulatorJS) + SMB share for native GameCube/Wii/Switch; datasets, stack, Caddy vhost, client setup, ROM acquisition |
| [Runner VM](setup-operations/runner-vm.md) | The classic TrueNAS VM on `br0` the GitHub runner runs in (SEC-1 step 4): host facts, rebuild from `vm/runner-vm/` cloud-init, failures |
| [Postgres major-version upgrade](setup-operations/postgres-major-upgrade.md) | Safe 15/16/17→18 datadir migration (dump→restore) per DB |
| [Portainer app deploy](setup-operations/portainer-app-deploy.md) | **Retired 2026-09-17; historical.** Applied Portainer's compose through the TrueNAS middleware until SVC-2 Phase 3 deleted the workflow |
| [Portainer GitOps migration](setup-operations/portainer-gitops-migration.md) | **Done; historical.** Moved web-editor stacks to Git stacks (since switched from polling to webhooks) |
| [deploy-stacks](setup-operations/deploy-stacks.md) | Push → Komodo deploy of each changed stack, new-stack creation, health gate, rollback, removing a stack |
| [Per-stack webhook deploy](setup-operations/portainer-webhook-deploy.md) | **Retired 2026-09-17; historical.** The Portainer webhook path it replaced, and why its gates exist |
| [CrowdSec bouncer](setup-operations/crowdsec-bouncer.md) | Turn CrowdSec detection into enforcement |
| [CrowdSec Console](setup-operations/crowdsec-console.md) | Enroll the LAPI for the hosted blocked-traffic dashboard |
| [Authentik socket hardening](setup-operations/authentik-socket-hardening.md) | **Applied** (worker has no socket, no root); the socket-proxy pattern if a Docker outpost is ever added |
| [Mealie behind Authentik (OIDC)](setup-operations/mealie-authentik-oidc.md) | Public Mealie access for friends via Authentik SSO, no VPN |
| [filebrowser → FileBrowser Quantum](setup-operations/filebrowser-to-quantum.md) | **Done 2026-09-09.** Replacing the archived filebrowser with `files`: why Quantum, the startup-fatal OIDC ordering rule, the on-NAS-clone race at cutover, why admin is `authentik Admins`, and rollback |
| [Jellyfin behind Authentik (SSO)](setup-operations/jellyfin-authentik-sso.md) | Public Jellyfin via SSO plugin; hides native login but keeps local creds alive for Seerr |
| [Deploy Matrix (Synapse) on Oracle A1](setup-operations/matrix-deploy.md) | Off-NAS Matrix homeserver: server_name delegation, open federation, Authentik SSO, mautrix bridges, backups to NAS |
| [Encrypted secret sync](setup-operations/secret-sync.md) | Share `.env` across devices via one passphrase; `secrets.sh push` writes Komodo Variables and deploys |
| [External heartbeat (healthchecks.io)](setup-operations/external-heartbeat.md) | Per-host dead-man's switch to an alerter outside the estate |
| [Kuma dual-monitoring setup](setup-operations/kuma-monitors.md) | How to configure monitors for the NAS and A1 (external) Kuma instances |
| [Docker image prune + boot guard](setup-operations/docker-image-prune.md) | Safe auto-prune of unused images (all hosts) and the boot guard that keeps dockerd from starting before its ZFS data-root. The Portainer image guard is retired |
| [Kiwix seeding](setup-operations/kiwix-seeding.md) | qBittorrent seeds the newest Kiwix ZIMs (offline Wikipedia, Gutenberg) inside a disk budget: the weekly script, its cron, and the Proton port forwarding it depends on |
| [Nightly Claude health check](setup-operations/nas-health-check.md) | Scheduled headless agent on the runner verifies alerts/pools/SMART/backup freshness+integrity/cloud sync/boot-guard/deployed stacks/containers/certs; failure = GitHub email |
| [Deploy-state probe](setup-operations/deploy-state-probe.md) | Deterministic gate that the estate matches the repo: placement, pinned digests, orphans, container health, caddy's proxy networks, host script copies. An exit code, not a model verdict — the Komodo migration's acceptance test |
| [Edge access policy probe](setup-operations/edge-access-policy-probe.md) | Scheduled assertion that admin hostnames are not internet-reachable: the VPS SNI allowlist checked from outside, Caddy's `@lan` exclusion of the VPS tailnet IP checked from the VPS |
| [NPMplus → Caddy migration](setup-operations/caddy-migration.md) | The edge move: host inventory, the Caddyfile shape, what was measured, cutover and rollback |
| [Cloudflare Tunnel for the orange-clouded names](setup-operations/cloudflare-tunnel-cutover.md) | **Designed, nothing built.** Removing the origin IP for `auth`/`files`/`immich`/`mealie`: why the `:8443` PROXY listener cannot carry it, the `:9443` tunnel listener, why the stack cannot land before the credentials, per-name DNS cutover and rollback |
| [Portainer EE → Komodo migration](setup-operations/komodo-migration.md) | **Phases 0–2 done 2026-09-15; Phase 3 (decommission) in progress since 2026-09-17.** The control-plane move: acceptance probe, findings F1–F32, adoptions, and the removal of Portainer |

> Adding a runbook → add a row here, in the right section.
