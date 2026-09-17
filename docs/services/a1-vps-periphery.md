# Service: Ampere A1 VPS Komodo periphery

## Overview

Komodo Periphery on the Ampere A1 VPS (**aarch64**). It is the agent Komodo Core, on the NAS, runs
`docker compose` through for every stack on this host: Core holds the resource model, the periphery
does the work. If it is down, Komodo can neither deploy nor inspect anything here. Containers keep
running either way.

Added 2026-09-15 in Phase 1 of the [Komodo migration](../runbooks/setup-operations/komodo-migration.md).
Running since 2026-09-15, Server state `Ok`. **Every stack on this host is Komodo's since 2026-09-15**
(Phase 2, §9): all six deploy through this periphery. The Portainer agent `a1-vps-agent` was removed on 2026-09-17.

## Stack

- **Stack folder:** `stacks/a1-vps-periphery/`
- **Compose file:** `stacks/a1-vps-periphery/docker-compose.yml`
- **Managed by:** the repo is the source of truth; **applied by hand**, never by Komodo.
  See [Why not Komodo](#why-not-komodo).
- **Host copy:** `/home/ubuntu/periphery/docker-compose.yml` (compose project `periphery`, container `komodo-periphery`).
- **Komodo Server:** `a1-vps`

## Why not Komodo

The periphery is the transport its own server deploys through, the same shape as the Portainer
agents had ([archive/a1-vps-agent.md](../archive/a1-vps-agent.md)): recreating it from Komodo drops the connection mid-command.
Plan findings F9 and F12. Enforced by its absence from `komodo/owned-stacks`, so a push that changes
this file deploys nothing, and by `HAND_APPLIED` in the deploy-state probe.

## Access

| Field | Value |
| ----- | ----- |
| Port | `8120` on the host network, bound to the tailnet IP `100.64.0.13` only (`PERIPHERY_BIND_IP`) |
| Auth | Noise handshake: only Core's key in `PERIPHERY_CORE_PUBLIC_KEYS` is accepted, and only from `PERIPHERY_ALLOWED_IPS` |
| UI | None. Managed from Komodo Core |

**Host network, not a published port, on purpose.** Docker SNATs traffic arriving on a published
port to the bridge gateway on this host (`172.22.0.1` on the A1, captured with `tcpdump` on
2026-09-15), so `PERIPHERY_ALLOWED_IPS: 100.64.0.11` refused Core with `401` until the periphery
moved onto the host network. There it sees the NAS's real tailnet address.

**Never start it without `PERIPHERY_CORE_PUBLIC_KEYS`.** An inbound periphery with no accepted key is an
unauthenticated Docker socket on `:8120` (F15). Terminals are disabled (`PERIPHERY_DISABLE_TERMINALS`).

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/var/run/docker.sock` | `/var/run/docker.sock` | The Docker API it drives |
| `/proc` | `/proc` | Host process and memory stats |
| `/etc/komodo` | `/etc/komodo` | Periphery root: repo clones, stack dirs, its key pair, Core's public key. Same path inside and out |

## Applying a change

Run from a clone of this repo, after the change is merged to `main`:

```sh
# 1. Back up, then write the repo copy (the directory is root-owned: pipe through sudo tee).
ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20 \
  'sudo cp /home/ubuntu/periphery/docker-compose.yml /home/ubuntu/periphery/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)'
cat stacks/a1-vps-periphery/docker-compose.yml \
  | ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20 'sudo tee /home/ubuntu/periphery/docker-compose.yml >/dev/null'

# 2. Confirm the pin landed, then pull and recreate.
ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20 \
  'grep -n "image:" /home/ubuntu/periphery/docker-compose.yml && cd /home/ubuntu/periphery && sudo docker compose pull && sudo docker compose up -d'
```

The directory name makes the compose project `periphery`, which the deploy-state probe files under
`stacks/a1-vps-periphery`. Do not rename it.

The `up -d` recreates the periphery, so Komodo shows Server `a1-vps` as unreachable for a few seconds.

## Version pinning

Pinned to `2.3.3@sha256:…`, the multi-arch manifest list, identical on all three hosts. Core and every
periphery move together (F2): Renovate groups the two images and holds them back from the merge
sweep, so bump Core first, then apply the three peripheries by hand.

## Related

- [komodo](komodo.md) — Core, the server this agent answers to
- [nas-periphery](nas-periphery.md), [a1-vps-periphery](a1-vps-periphery.md), [micro-vps-periphery](micro-vps-periphery.md)

## Last updated

2026-09-15 — every A1 stack now deploys through this periphery (Phase 2).
