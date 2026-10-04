# Service: NAS Komodo periphery

## Overview

Komodo Periphery on the NAS (**x86_64**). It is the agent Komodo Core, on the NAS, runs
`docker compose` through for every stack on this host: Core holds the resource model, the periphery
does the work. If it is down, Komodo can neither deploy nor inspect anything here. Containers keep
running either way.

It runs the host's compose plugin rather than the bundled one ([below](#volumes--data)). Env reaches it as
the `.env` Komodo writes from Variables into `/mnt/apps/komodo/repos/nas/stacks/<stack>/`.

That clone is also live config. These containers mount their config from it:

- `caddy`: its Caddyfile directory.
- The `authentik` worker: its blueprints.
- `vector`, `victoriametrics` and `grafana` in `observability`.
- `files`.

Never delete or move `/mnt/apps/komodo/repos/nas` while they run. The next deploy would clone afresh,
the mounts would stay on the deleted directory, and those Stacks' `post_deploy` checks would fail
([komodo.md → Rules](komodo.md#config-mounts-come-from-komodos-clone)).

## Stack

- **Stack folder:** `stacks/nas-periphery/`
- **Compose file:** `stacks/nas-periphery/docker-compose.yml`
- **Managed by:** the repo is the source of truth; **applied by hand**, never by Komodo.
  See [Why not Komodo](#why-not-komodo).
- **Host copy:** the on-NAS clone, `/mnt/apps/scripts/nas/stacks/nas-periphery/`, which `git-pull-nas.sh` keeps on `main` (compose project `periphery`, container `komodo-periphery`).
- **Komodo Server:** `nas`

## Why not Komodo

The periphery is the transport its own server deploys through,: recreating it from Komodo drops the connection mid-command
([komodo.md → Rules](komodo.md#peripheries-are-hand-applied)). Enforced by its absence from `komodo/owned-stacks`, so a push that changes
this file deploys nothing, and by `HAND_APPLIED` in the deploy-state probe.

## Access

| Field | Value |
| ----- | ----- |
| Port | `8120`, bound to `192.168.1.111:8120` only |
| Auth | Noise handshake: only Core's key in `PERIPHERY_CORE_PUBLIC_KEYS` is accepted, and only from `PERIPHERY_ALLOWED_IPS` |
| UI | None. Managed from Komodo Core |

**`PERIPHERY_ALLOWED_IPS` is weak here, and says so.** Core reaches the published LAN port from
its own bridge, and Docker MASQUERADEs that to the periphery network's gateway. So the allowed
address is `172.31.120.1`, the gateway of this project's pinned subnet: LAN clients are refused, any
container on the NAS is not. Core's key is the real gate.

**Never start it without `PERIPHERY_CORE_PUBLIC_KEYS`.** An inbound periphery with no accepted key is an
unauthenticated Docker socket on `:8120`. Terminals are disabled (`PERIPHERY_DISABLE_TERMINALS`).

## Volumes / data

| Container path | Host path | Purpose |
| -------------- | --------- | ------- |
| `/var/run/docker.sock` | `/var/run/docker.sock` | The Docker API it drives |
| `/proc` | `/proc` | Host process and memory stats |
| `/mnt/apps/komodo` | `/mnt/apps/komodo` | Periphery root: repo clones, stack dirs, its key pair, Core's public key. Same path inside and out |
| `/usr/libexec/docker/cli-plugins/docker-compose` (ro) | same | The host's compose 2.32.3 instead of the image's 5.5.0, which fails on TrueNAS's IPv6 gateway format. Moves with TrueNAS updates |

## AppArmor

The container runs `apparmor=unconfined`. Under Docker's `docker-default` profile, every host-process
read through the `/proc` mount was denied (`apparmor="DENIED" operation="ptrace" ... comm="tokio-rt-worker"`,
`proctitle="periphery"`): about 144 denials a minute, three audit records each. The kernel hands
those to journald as well as auditd, and on 2026-09-27 they were 78% of the NAS journal. That filled
journald's 6.25 MB files every ~13 min, and it was during one of those rotations that journald
deadlocked in ZFS that morning, taking cron, SSH and the TrueNAS UI login down with it until a reboot.

The profile protected nothing: the container holds the Docker socket, which is root on the host.
The denials also left `exe` empty for every host process in Komodo's process list.

Only the NAS needs this. The VPS peripheries log no denials (0 on the A1 in 15 min).

## Applying a change

Run after the change is merged **and** the on-NAS clone has pulled it (`git -C /mnt/apps/scripts/nas log -1`):

```sh
ssh -i secrets/ssh/truenas_ed25519 truenas_admin@192.168.1.111
cd /mnt/apps/scripts/nas/stacks/nas-periphery
sudo docker compose -p periphery config --quiet
sudo docker compose -p periphery pull
sudo docker compose -p periphery up -d
sudo docker ps --filter name=komodo-periphery --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

`-p periphery` is load-bearing: the deploy-state probe files project `periphery` on endpoint `nas`
under `stacks/nas-periphery`, and any other project name is a `NO REPO COMPOSE` FAIL.

The `up -d` recreates the periphery, so Komodo shows Server `nas` as unreachable for a few seconds.

## Version pinning

Pinned to `2.3.3@sha256:…`, the multi-arch manifest list, identical on all three hosts. Core and every
periphery move together ([komodo.md → Upgrade](komodo.md#upgrade)): Renovate groups the two images and holds them back from the merge
sweep, so bump Core first, then apply the three peripheries by hand.

## Related

- [komodo](komodo.md) — Core, the server this agent answers to
- [nas-periphery](nas-periphery.md), [a1-vps-periphery](a1-vps-periphery.md), [micro-vps-periphery](micro-vps-periphery.md)
