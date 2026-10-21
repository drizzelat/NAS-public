# Service: PBS guest node

## Overview

A small Tailscale node, `pbs-guest`, that reaches the [pbs](pbs.md) stack and is meant to be **shared
with one outside person** (the lecture teammate, whose own tailnet the PVE host's `jumphost` is in).
It exposes three TCP ports: `:443` is a dedicated Caddy that serves `pbs.example.com` and
`pve.example.com` with a real certificate, and `:8006` (the lecture PVE host's web UI) and `:8007`
(Proxmox Backup Server) are raw forwards for use without the names. It exists so a guest can reach
those two things and nothing else of the NAS.

Why a node of its own, and not the NAS or Caddy: Caddy's `lan_only` rule admits all of
`100.64.0.0/10`, so a guest on the tailnet who could reach the edge Caddy would pass every internal vhost. PBS itself is fully open to the guest (admin); the node keeps everything else of the NAS out of reach.
The guest node has no route to the edge Caddy; it sits on the `proxy_pbs` network and its serve config
names three upstreams: its own Caddy and the two services.

## Stack

- **Stack folder:** `stacks/pbs-guest/`
- **Compose file:** `stacks/pbs-guest/docker-compose.yml`
- **Deploy:** Komodo Stack `pbs-guest` on Server `nas` ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its
  folder deploys it through Komodo.
- **Image:** `tailscale/tailscale`, userspace mode (no tun device, no `NET_ADMIN`), the same pin as
  [tailscale](tailscale.md).

## Access

| | |
|---|---|
| URL | `https://pbs.example.com` and `https://pve.example.com` from the guest's tailnet (public DNS-only records point both at the node's tailnet address, so nothing is needed on the guest's machine). Without the names: `https://<pbs-guest tailnet IP>:8007` and `:8006`, with a certificate warning |
| Port | `443/tcp` (the guest Caddy), `8006/tcp`, `8007/tcp` on the `pbs-guest` tailnet node only. No LAN port |
| Auth | PVE: the PVE host's own logins. PBS: `guest@pbs`, a full admin (`Admin` on `/`), because the server is used for the lecture only and both partners need all of it |

The tailnet ACL ([`tailscale/policy.hujson`](../../tailscale/policy.hujson)) lets `autogroup:shared`
reach the node on those two ports only. Tailscale rules match node and port, not domain names; the name-level
limit is the guest Caddy, which serves exactly two hostnames and `abort`s everything else.

## Volumes / data

| Container path | Host path | Purpose |
|---|---|---|
| `/var/lib/tailscale` (tailscale) | `/mnt/apps/pbs/guest` | The node's key (inside the `apps/pbs` dataset) |
| `/data` (caddy) | `/mnt/apps/pbs/guest-caddy` | The guest Caddy's wildcard certificate and ACME account |

## Environment variables

| Variable | Description |
|---|---|
| `TS_AUTHKEY` | One-off Tailscale auth key for the `pbs-guest` node, **not tagged** (a tagged node cannot be shared reliably). Vault `stack-env/pbs-guest.env.age`, Komodo Variable `PBS_GUEST__TS_AUTHKEY`. Only read on the first start |
| `CLOUDFLARE_API_TOKEN` | The same Cloudflare DNS-edit token the edge [caddy](caddy.md) uses, for the guest Caddy's DNS-01 challenge. Komodo Variable `PBS_GUEST__CLOUDFLARE_API_TOKEN`. **A second home for that token**, on a container a guest can reach over the tailnet: rotate both together |

## Dependencies

- The [pbs](pbs.md) stack, for the `proxy_pbs` network and the two upstreams (`pbs`, `pbs-tunnel`).
  If the tunnel is down, `:8006` fails and the PVE host's backups fail too.
- The Tailscale control plane, for the node to come up, and Let's Encrypt plus the Cloudflare API, for the guest Caddy's certificate.

## Notes

- **Share only this node.** `autogroup:shared` in the ACL means every user a node of yours is shared
  with; the rule names this node's address, but never share `nas` for the same reason as above.
- The serve config and the guest Caddyfile are inline in the compose file (`configs:`), so there is no host file to keep in sync.
- **The guest Caddy has its own wildcard certificate** (`*.example.com`, DNS-01), separate from the edge Caddy's, so
  the two names stay out of Certificate Transparency like the other internal hosts. The names themselves are public in DNS.
- **Public DNS.** `pbs.` and `pve.` have DNS-only A records (Cloudflare, tracked in `cloudflare/dns-records.json`
  and `tailnet_dns` in [`.github/estate.yml`](../../.github/estate.yml)) pointing at the node's `100.x` address. Anyone can
  resolve that address; only a guest the node is shared with can reach it. On **your** network AdGuard still answers
  those two names with the NAS, so you are unaffected. Some home routers drop DNS answers in `100.64.0.0/10`
  (DNS-rebinding protection); if the guest gets no address, a hosts-file entry on their machine does the same job.
- If the node is ever re-created its `100.x` address changes: update the two DNS records, the ACL rule and `cloudflare/dns-records.json`.
- Revoking access: stop sharing the node in the Tailscale console (Machines → `pbs-guest` → Share),
  or delete the ACL rule.

## Operations

> Restart/redeploy go through **Komodo** (Stack `pbs-guest`), which deploys from `komodo/resources.toml`. Over SSH, `truenas_admin` is not in the `docker` group but has passwordless sudo, so `sudo -n docker …` works for inspection.

### First setup

1. Tailscale admin console → Settings → Keys → **Generate auth key**: description `pbs-guest`, reusable off,
   ephemeral off, pre-approved on, no tags. Put it in the vault: `scripts/secrets.sh edit pbs-guest`
   (`TS_AUTHKEY=tskey-auth-…`) and `scripts/secrets.sh komodo-vars pbs-guest`, **before** merging.
2. Merge. In the console, open the new `pbs-guest` machine, note its `100.x` address, and **disable key
   expiry** (or the node drops off after 180 days).
3. Add the ACL rule with that address in a PR (ACL runbook):

   ```jsonc
   { "action": "accept", "src": ["autogroup:shared"], "dst": ["<pbs-guest tailnet IP>:443,8006,8007"] },
   ```

   and two Cloudflare DNS-only A records, `pbs` and `pve`, to that address (also in `cloudflare/dns-records.json`).

4. Share the node: Machines → `pbs-guest` → Share → the guest's Tailscale account (an invite link).
   They accept it in their console.
5. Give the guest `guest@pbs` and its password (in the gitignored `secrets/pbs-credentials.txt`), and ask them to change it in the PBS UI.

### Restart / redeploy

Komodo → Stacks → `pbs-guest` → **Restart** or **Deploy**, or push to `stacks/pbs-guest/`.

### Upgrade

Every image is pinned `tag@sha256:digest`; Renovate bumps it with the [tailscale](tailscale.md) pin and
the renovate-pr-review flow merges it. Rollback = revert + redeploy.

### Restore from backup

The node key is in `apps/pbs`, covered by the `apps` snapshots and the Hetzner sync. A lost key is
fixed with a fresh `TS_AUTHKEY` and a new share; the address changes, so update the ACL rule.

### Common failures

- **Guest sees the node but connections time out**: the ACL rule is missing or names the wrong address.
- **After changing the serve config or Caddyfile in the compose file, the Tailscale container may keep the old one**: `docker exec pbs-guest tailscale serve status` must list `:443`, `:8006` and `:8007`. If not, `docker rm -f pbs-guest pbs-guest-caddy` and redeploy (the node key persists).
- **The names do not resolve for the guest, or give a certificate error**: see the DNS note above (rebind filter); a certificate error on first use means the guest Caddy is still issuing, `docker logs pbs-guest-caddy` shows it.
- **`8006` fails, `8007` works**: the `pbs-tunnel` container is down; see [pbs](pbs.md#common-failures).
- **Node offline after months**: key expiry was not disabled (First setup step 2).
