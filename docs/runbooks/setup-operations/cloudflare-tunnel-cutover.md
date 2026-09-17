# Runbook: Cloudflare Tunnel for the orange-clouded names

**Status: designed, nothing built.** No tunnel exists, no DNS has moved, no stack is in the repo.
This is the plan and the reasoning; every phase below is still to do.

## Why

`jellyfin` is gray-cloud by necessity (video streaming, Cloudflare ToS §2.8), so its `A` record
publishes the ingress VPS address `198.51.100.10`. That makes the origin public knowledge for
**every** name on that front door. Until the Cloudflare-only gate landed
([micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Layer 1b), anyone who resolved
`jellyfin` could open a direct connection to the VPS with `auth`, `files`, `immich` or `mealie` in
the SNI and reach the origin with Cloudflare's WAF, bot rules and managed challenges skipped
entirely. Measured, before that gate:

```
auth      direct-to-origin: 302     via-cloudflare: 302
files     direct-to-origin: 200     via-cloudflare: 200
immich    direct-to-origin: 200     via-cloudflare: 200
mealie    direct-to-origin: 200     via-cloudflare: 200
```

The gate closes the hole by IP. A tunnel closes it by construction: with those four served over
`cloudflared`, there is no origin address for them to be reached at, and the VPS front door shrinks
to the one name that genuinely needs a public IP.

> **The gate is the fix; this is the end state.** Do not treat this runbook as a reason to delay or
> revert Layer 1b. If this migration never happens, the gate alone is a complete answer.

## End state

```
                        today                              after
  auth ─┐                                    auth ─┐
  files ├─ Cloudflare ─ VPS nginx ─ tailnet ─┤     ├─ Cloudflare ─ tunnel ─ cloudflared ─ Caddy :9443
  immich┤   (SNI map, geo gate)               immich┤   (no origin IP at all)
  mealie┘                                    mealie┘
  jellyfin ─ (gray) ──── VPS nginx ─ tailnet ─ jellyfin ─ (gray) ─ VPS nginx ─ tailnet ─ Caddy :8443
```

The VPS keeps `jellyfin` and the `:80` redirect leg. Its SNI map goes from five names to one, so
there is nothing left to bypass *to* — and Layer 1b's `geo` block becomes belt-and-braces for a
single gray-cloud name rather than the thing holding the line.

## What this does not change

- **Cloudflare is already in front of these four.** They are orange-clouded today, so no content
  moves onto Cloudflare that is not already there — the ToS §2.8 question is unchanged, and
  `jellyfin` still stays off it.
- **The access model.** LAN/tailnet keeps hitting Caddy `:443` directly via AdGuard rewrites.
- **Per-app auth.** Authentik, the OIDC connectors and the Jellyfin edge password block are
  untouched.

## Prerequisites (Cloudflare side, manual — cannot be scripted from this repo)

The repo holds a Cloudflare **DNS** token for the DNS-01 wildcard challenge. Creating a tunnel needs
a different, account-scoped credential and mints a secret of its own, so these steps are done by
hand, once:

1. Create the tunnel — `cloudflared tunnel create nas` — which writes a credentials JSON
   (`<TUNNEL_ID>.json`). **That file is the tunnel.** It goes in `secrets/` and its ciphertext in
   `secrets.enc/`, exactly like every other secret here; it never lands in git in the clear.
2. Note the tunnel UUID. The DNS target is `<TUNNEL_ID>.cfargotunnel.com`.
3. Do **not** create the DNS records yet — that is Phase 3, one name at a time.

> **Locally-managed, not dashboard-managed.** A token-based (remote-managed) tunnel keeps its
> ingress rules in the Cloudflare dashboard, which puts routing back into click-ops — the thing
> [edge-access-policy-probe.md](edge-access-policy-probe.md) exists to get away from. Locally-managed
> keeps the ingress rules in git next to the Caddyfile, where the SNI map and the access policy
> already live, and the probe can assert them.

## Phase 1 — a tunnel listener on Caddy

`cloudflared` cannot emit a PROXY-protocol header, so it cannot use the `:8443` listener: that
wrapper is `fallback_policy reject` and only accepts the VPS tailnet IP, which is the property that
keeps a forged PROXY header off the edge. Relaxing it to `ignore` to accommodate the tunnel would
trade away a real guarantee. Give the tunnel its own listener instead.

- Add `https://<name>.example.com:9443` as a third address on the `auth`, `files`, `immich` and
  `mealie` site blocks. **Not** on `jellyfin` and not on any LAN-only name — anything else arriving
  on `:9443` falls through to the `*.example.com` catch-all, which `abort`s. That is the same
  default-deny the other listeners rely on.
- Add a `servers :9443` block mirroring the `:8443` one, minus the PROXY wrapper:

  ```caddyfile
  servers :9443 {
      trusted_proxies static <the cloudflared container's network>
      client_ip_headers CF-Connecting-IP
  }
  ```

  cloudflared forwards `CF-Connecting-IP` to the origin, so the real client IP survives the same way
  it does today — see [caddy.md](../../services/caddy.md) → Real client IP behind Cloudflare. The
  trusted peer here is the cloudflared container, not Cloudflare's published ranges: nothing else
  can reach `:9443`.
- Verify `remote_ip` semantics have not moved: every `@lan` matcher must still see the container
  address and therefore still deny. `:9443` carries no LAN-only site block, so this is belt and
  braces, but check it rather than assume it.

**Verify:** `caddy validate`, then from the NAS `curl --resolve auth.example.com:9443:127.0.0.1`
and confirm a normal answer, while a LAN-only name on `:9443` aborts.

## Phase 2 — the `cloudflared` stack

**Do not land this stack in the repo until the credentials exist and work.** A new
`stacks/<name>/` directory pushed to `main` is not inert: `scripts/deploy/fire-webhooks.sh` creates
and starts it in Portainer automatically (the "NEW stack on endpoint" path), a credential-less
cloudflared would crashloop, `verify-healthy.sh` would fail, and the auto-revert would undo the
newest stack change — which may not be this one. Build it, test it by hand on the NAS, and commit
it in the same change that has a working tunnel.

- `stacks/cloudflared/docker-compose.yml`, ingress rules inlined as a Compose `config` — the same
  shape as the VPS nginx, and for the same reason.
- Ingress lists exactly the four names, each to `https://caddy:9443` with `originServerName` set so
  the wildcard certificate verifies. A catch-all `http_status:404` rule last.
- Credentials JSON bind-mounted read-only from a path on the NAS, not baked into the image and not
  in the compose.
- Two replicas if the four are to survive a single container restart; one is fine to start.
- Needs `docs/services/cloudflared.md` in the same commit — `docs-drift.py` fails the build
  otherwise, and it publishes no LAN port and needs no `docs/network.md` row.

**Verify:** `cloudflared tunnel info` shows the connector registered, with DNS still pointing at the
VPS. Nothing is serving through it yet.

## Phase 3 — DNS cutover, one name at a time

Per name, least-blast-radius first — suggested order `mealie`, `files`, `immich`, `auth`:

1. `cloudflared tunnel route dns nas <name>.example.com` — replaces the proxied `A` with a proxied
   `CNAME` to `<TUNNEL_ID>.cfargotunnel.com`.
2. Watch Kuma for that monitor, plus the Caddy access log: `service:caddy AND host:"<name>…"` should
   keep flowing, now with the cloudflared container as `remote_ip` and the real visitor as
   `client_ip`.
3. Confirm the direct path is dead: `curl --resolve <name>.example.com:443:198.51.100.10` should
   fail — first because Layer 1b already refuses a non-Cloudflare peer, then because Phase 4 removes
   the name from the map entirely.

`auth` last: Authentik is the OIDC provider for `files`, `immich` and `mealie`, so breaking it
breaks their logins too. Do it when there is time to watch it.

**Rollback per name:** put the proxied `A` record back to `198.51.100.10`. The VPS still has the
name in its SNI map throughout Phase 3, which is exactly why Phase 4 is separate.

## Phase 4 — shrink the front door

Only once all four have been stable on the tunnel for a few days:

- Remove the four from the SNI map in `stacks/micro-vps-ingress/docker-compose.yml`, leaving
  `jellyfin`. The `geo $cf_edge` block can stay — it costs nothing and keeps the gate in place if a
  name ever moves back.
- Update `PUBLIC_HOSTS` / `CF_ONLY_HOSTS` in
  [`edge-access-policy.yml`](../../../.github/workflows/edge-access-policy.yml): the four become
  ordinary `blocked` cases at the VPS, since they should no longer be forwarded from anywhere.
- Layer 2's case list keeps all five — that probe reaches Caddy directly over the tailnet and is
  unaffected by any of this.
- Kuma keeps probing all five through Cloudflare; that is now the only liveness assertion for the
  four, as it already is today.

## Risks worth naming before starting

- **New single point of failure.** Four services gain a dependency on `cloudflared` and on
  Cloudflare's control plane. The VPS path is a known quantity with a break-glass copy on the host;
  the tunnel is neither, until it has run a while.
- **Debuggability drops.** A stream proxy fails visibly (connection closed, `525`). A tunnel fails
  as a `1033`/`530` from Cloudflare with the useful detail on Cloudflare's side.
- **Two edges to reason about instead of one.** Until Phase 4 completes there are two live public
  paths with different real-IP mechanisms, PROXY-protocol and `CF-Connecting-IP`.
- **The credentials JSON is a bearer secret.** Anyone holding it can serve traffic as this tunnel.
  It belongs in `secrets.enc/` with the rest, and rotating it means recreating the tunnel.

## Decision

Not started, and not urgent: [#314](https://github.com/drizzelat/NAS/pull/314) closes the bypass
this migration was proposed to fix. The case for doing it anyway is that it removes a moving part
(the VPS drops from five names to one) rather than adding one, and it makes the bypass
*structurally* impossible instead of IP-gated. The case against is everything under Risks. Revisit
when the tunnel would be carrying something the gate cannot protect.
