# Runbook: Harden Authentik's Docker socket access

> **Status: applied — Case A.** [`stacks/authentik/docker-compose.yml`](../../../stacks/authentik/docker-compose.yml)
> runs the worker with no Docker socket and no `user: root`, and no Docker-type outpost exists. The
> text below records the original risk and keeps Case B for the day a Docker outpost is needed.
> (The embedded outpost no longer fronts anything either — `files` moved to native OIDC on 2026-09-09.)

## The risk

The Authentik **worker** used to mount the raw Docker socket as **root**:

```yaml
worker:
  user: root
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
```

`docker.sock` + root = full control of the host (anyone who can run code in the worker can start a
privileged container and escape). Authentik is one of the few **internet-facing** services
(it fronts `auth` and `files` via the embedded outpost), so this is the highest-value mount on the
box to lock down.

The worker only needs the socket to manage **Docker-type outpost integrations** (it spins up and
updates outpost containers via the Docker API). The **embedded** outpost — what this setup uses to
front filebrowser — runs *inside* the `server` container and does **not** need the socket.

## Decide which fix applies

In Authentik admin: **System → Outposts → Integrations** (and **Outposts**).

### Case A — no Docker-type outpost / integration in use (most likely here)

The socket is dead weight. Remove it and drop the root user from the `worker` service:

```yaml
worker:
  # user: root            # delete
  volumes:
    # - /var/run/docker.sock:/var/run/docker.sock   # delete
    - /mnt/apps/authentik/media:/media
    - /mnt/apps/authentik/certs:/certs
    - /mnt/apps/authentik/custom-templates:/templates
```

Redeploy. The built-in "local" Docker integration will show *unhealthy* (it has nothing to talk
to) — harmless if no Docker outpost depends on it.

### Case B — a Docker outpost integration IS in use

Keep the capability but remove raw root-socket access by putting a **read-scoped socket proxy** in
front. Add to the authentik stack:

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    restart: unless-stopped
    environment:
      CONTAINERS: 1
      IMAGES: 1
      NETWORKS: 1
      POST: 1          # outpost management needs to create/start/stop containers
      INFO: 1
      VERSION: 1
      EXEC: 0
      VOLUMES: 0
      SECRETS: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - authentik_net
```

Then remove the socket mount + `user: root` from `worker` (as in Case A) and, in Authentik,
edit the Docker integration to use URL `tcp://docker-socket-proxy:2375` (no TLS, internal
network). The proxy never exposes the raw socket and blocks the dangerous endpoints.

## Why this isn't applied automatically

Switching the integration URL is stored in Authentik's database (a UI action), not in compose, and
this is internet-facing auth — a blind change could lock SSO. Verify the case above first, then
apply.
