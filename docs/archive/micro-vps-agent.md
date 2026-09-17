# Service: micro VPS Portainer agent

> **Archived 2026-09-17.** The Portainer agent on the micro VPS was removed in SVC-2 Phase 3, with
> Portainer itself ([archive/portainer.md](portainer.md)): `docker compose -p agent down`, then
> `/home/ubuntu/agent` deleted, and `stacks/micro-vps-agent/` removed from the repo. Nothing here describes anything
> running. The micro VPS's transport is now its Komodo periphery. To restore the agent, take its compose
> from git history.

## Overview

Portainer Agent on the Oracle micro VPS. This is the **transport** the NAS Portainer
uses to reach **endpoint 4** — every `micro-vps-*` stack is deployed *through* this
container. If it is down, endpoint 4 is unreachable and nothing on the micro VPS can
be deployed or inspected from the Portainer UI.

Added to the repo 2026-09-08. Before that it existed only as a hand-written compose
file on the host, pinned to `portainer/agent:latest`, which nothing watched — it sat
on **2.39.4** while the Portainer server advanced to 2.45.0, and the version-mismatch
warning in the UI was the only signal.

## Stack

- **Stack folder:** `stacks/micro-vps-agent/`
- **Compose file:** `stacks/micro-vps-agent/docker-compose.yml`
- **Managed by:** the repo is the source of truth; **applied over SSH**, *not* by
  Portainer GitOps (see [Why not GitOps](#why-not-gitops)).
- **Runs on:** the Oracle micro VPS ([host + SSH details](micro-vps-ingress.md)).
- **Host copy:** `/home/ubuntu/agent/docker-compose.yml` (compose project `agent`,
  container `agent-portainer_agent-1`).

## Why not GitOps

Every other `micro-vps-*` stack deploys through this agent. Deploying **the agent
itself** through the agent is self-referential: Portainer proxies the Docker API over
the agent tunnel, so the moment the agent container stops, the tunnel drops and any
remaining call (notably `start`) never lands. That can leave the container
created-but-not-started, with endpoint 4 down and SSH the only way back in.

This is the same reason Portainer on the NAS is a TrueNAS app rather than one of its
own stacks. Enforced in `scripts/deploy/fire-webhooks.sh`: `micro-vps-agent` is on
both `CREATE_SKIP` and `RECONCILE_SKIP`. A push that changes this file logs
`'micro-vps-agent' is new but on CREATE_SKIP — create it in Portainer by hand` and
deploys nothing. That warning is expected; apply it by SSH instead.

## Applying a change

Run from a clone of this repo, after the change is merged to `main`.

`/home/ubuntu/agent/` is **root-owned** (`drwxr-xr-x root root`), so `scp` as `ubuntu`
fails with `Permission denied`. Pipe through `sudo tee` instead. Back up first — and
note that a failed copy followed by a `pull` silently pulls whatever the *old* file
says, so always confirm the pin landed before recreating anything.

```sh
# 1. Back up the current host copy.
ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10 \
  "sudo cp /home/ubuntu/agent/docker-compose.yml \
           /home/ubuntu/agent/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)"

# 2. Write the repo copy over it (sudo tee — scp cannot write here).
cat stacks/micro-vps-agent/docker-compose.yml \
  | ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10 \
      'sudo tee /home/ubuntu/agent/docker-compose.yml >/dev/null'

# 3. CONFIRM the pin landed before touching the container.
ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10 \
  'grep -n "image:" /home/ubuntu/agent/docker-compose.yml'

# 4. Pull and recreate.
ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10 \
  'cd /home/ubuntu/agent && sudo docker compose pull && sudo docker compose up -d'
```

The `up -d` recreates the agent, so the Portainer UI shows endpoint 4 as down for a
few seconds. That is expected. Confirm it came back before walking away:

```sh
ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10 \
  'sudo docker ps --filter name=agent --format "{{.Names}}\t{{.Image}}\t{{.Status}}"'
```

Then check the environment is green in Portainer → Environments.

### Rolling back

Step 1 leaves a timestamped copy beside the live file. To go back, `sudo cp` the
chosen `docker-compose.yml.bak-*` over `docker-compose.yml` and re-run step 4. The
pre-pin originals from 2026-09-08 (`portainer/agent:latest`, agent 2.39.4) are kept
on both hosts as `docker-compose.yml.bak-20260908-*`.

## Version pinning

Pinned to an explicit version + digest so Renovate tracks it. `latest` is wrong here:
it only resolves at pull time, so once the container exists it never moves — that is
exactly how this drifted to 2.39.4.

The digest is the **multi-arch manifest list**, so the identical pin is correct on
this host (x86_64) and on the [A1](a1-vps-agent.md) (aarch64); Docker resolves the
right architecture from it.

**Keep the agent version matched to the Portainer server** in
`stacks/portainer/docker-compose.yml`. Portainer warns on a mismatch in the
Environments list. Order matters: bump the **server first**, then the agents.

## Network

| Port   | Bind                  | Notes                                           |
| ------ | --------------------- | ----------------------------------------------- |
| `9001` | `100.64.0.12:9001`  | Tailnet IP only — never bound on the public IP   |

## Related

- [micro-vps-ingress](micro-vps-ingress.md) — host, SSH, firewall
- [a1-vps-agent](a1-vps-agent.md) — the same agent on the A1 (endpoint 5)
- [portainer](portainer.md) — the server these agents connect to
