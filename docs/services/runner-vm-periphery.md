# Service: runner VM Komodo periphery

## Overview

Komodo Periphery on the [runner VM](../runbooks/setup-operations/runner-vm.md) (**x86_64**). It is the agent Komodo Core runs
`docker compose` through for every stack on this host: the
[GitHub runner](github-runner.md), since 2026-09-17. If it is down, Komodo can neither deploy nor inspect anything here. Containers keep running
either way.

Added 2026-09-17 in Phase 3 of the [Komodo migration](../runbooks/setup-operations/komodo-migration.md),
Server state `Ok` since.

## Stack

- **Stack folder:** `stacks/runner-vm-periphery/`
- **Compose file:** `stacks/runner-vm-periphery/docker-compose.yml`
- **Managed by:** the repo is the source of truth; **applied by hand**, never by Komodo.
  See [Why not Komodo](#why-not-komodo).
- **Host copy:** `/home/ubuntu/periphery/docker-compose.yml` on the VM (compose project `periphery`,
  container `komodo-periphery`).
- **Komodo Server:** `runner-vm`

## Why not Komodo

The periphery is the transport its own server deploys through (plan F12): recreating it from Komodo
drops the connection mid-command. Enforced by its absence from `komodo/owned-stacks`, so a push that
changes this file deploys nothing, and by `HAND_APPLIED` in the deploy-state probe.

## Access

| Field | Value |
| ----- | ----- |
| Port | `8120` on the host network, bound to the VM's LAN address `192.168.178.34` only (`PERIPHERY_BIND_IP`) |
| Auth | Noise handshake: only Core's key in `PERIPHERY_CORE_PUBLIC_KEYS` is accepted, and only from `PERIPHERY_ALLOWED_IPS` |
| UI | None. Managed from Komodo Core |

**`PERIPHERY_ALLOWED_IPS` is `192.168.178.111`, the NAS.** Core runs in a container on the NAS, and its
traffic to the VM leaves the NAS masqueraded as the NAS's LAN address. Measured 2026-09-17, both ways:
- **The real allowlist:** the Server went `Ok`.
- **A wrong one, `192.168.178.1`:** the Server went `NotOk`.

**Never start it without `PERIPHERY_CORE_PUBLIC_KEYS`** (F15). Core's `core.pub` is written by the VM's
cloud-init before the first start. Terminals are disabled.

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/var/run/docker.sock` | `/var/run/docker.sock` | The Docker API it drives (the VM's, not the NAS's) |
| `/proc` | `/proc` | Guest process and memory stats |
| `/etc/komodo` | `/etc/komodo` | Periphery root: repo clones, stack dirs, its key pair, Core's public key. Same path inside and out |

## Applying a change

From a clone of this repo, after the change is merged to `main`:

```sh
K=secrets/ssh/runner-vm_ed25519; H=ubuntu@192.168.178.34
ssh -i $K $H 'sudo cp /home/ubuntu/periphery/docker-compose.yml /home/ubuntu/periphery/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)'
cat stacks/runner-vm-periphery/docker-compose.yml | ssh -i $K $H 'sudo tee /home/ubuntu/periphery/docker-compose.yml >/dev/null'
ssh -i $K $H 'cd /home/ubuntu/periphery && sudo docker compose pull && sudo docker compose up -d'
```

The directory name makes the compose project `periphery`, which the deploy-state probe files under
`stacks/runner-vm-periphery`. Do not rename it.

## Version pinning

The same `2.3.3@sha256:…` as every periphery. Core and all four peripheries move together (F2).

## Related

- [runner-vm](../runbooks/setup-operations/runner-vm.md) — the VM it runs in
- [komodo](komodo.md) — Core, the server this agent answers to
- [nas-periphery](nas-periphery.md), [a1-vps-periphery](a1-vps-periphery.md), [micro-vps-periphery](micro-vps-periphery.md)

## Last updated

2026-09-17
