# Runbook: VPS ingress backhaul over Tailscale

How the public ingress backhaul works and how to (re)build it. Background + steady-state
details: [services/micro-vps-ingress.md](../../services/micro-vps-ingress.md).

## How it works

The Oracle VPS is the public front door — it holds the public IP; the CGNAT'd NAS has none. The
VPS's nginx stream-forwards public `:80/:443` to the NAS's tailnet IP, so the NAS runs a
**Tailscale** node (subnet router, [tailscale.md](../../services/tailscale.md)) and the VPS reaches
it over WireGuard. No shared token, encrypted transport, and the VPS is a Komodo Server over the
tailnet.

```text
Internet :80/:443 → (Cloudflare) → VPS nginx (stream) → Tailscale → NAS Caddy :80 / :8443 → services
```

- VPS tailnet IP `100.64.0.12`; NAS tailnet peer `nas` `100.64.0.11`.
- nginx is the Komodo Stack [`stacks/micro-vps-ingress/`](../../../stacks/micro-vps-ingress/)
  (config inlined in the compose file): `:80` → `100.64.0.11:80`, and `:443` → through the SNI
  allowlist `map` → `100.64.0.11:8443` with PROXY protocol.

## Build the backhaul

1. **Install + join Tailscale on the VPS.**

   ```sh
   ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --ssh --accept-routes      # visit the printed URL to authenticate
   sudo tailscale ip -4                          # -> 100.64.0.12
   ```

   The tailnet ACL must let this node reach the NAS on `:80` **and** `:8443`.
2. **Verify the tunnel path** (real SNI, from the VPS):

   ```sh
   curl -sk --resolve files.example.com:443:100.64.0.11 \
     https://files.example.com -o /dev/null -w '%{http_code}\n'   # expect 200
   ```

   > Plain `curl https://100.64.0.11` (no SNI) fails the TLS handshake at Caddy — expected. Always test with SNI.
3. **Add the VPS to Komodo** as a Server: apply [`stacks/micro-vps-periphery/`](../../../stacks/micro-vps-periphery/)
   over SSH, tailnet-only on `100.64.0.12:8120` ([micro-vps-periphery](../../services/micro-vps-periphery.md)),
   with its `[[server]]` entry in `komodo/resources.toml`. (Until 2026-09-17 this step added a
   Portainer agent on `:9001`.)
4. **Deploy nginx** — the `micro-vps-ingress` Komodo Stack on Server `micro-vps`. It has no env, so
   `deploy-stacks` creates it from its `resources.toml` entry on the first push.
5. **Close the access-control hole (security-critical).** The VPS forwards public traffic from its
   tailnet IP `100.64.0.12`, which is inside `100.64.0.0/10` — the range Caddy's LAN-only `@lan`
   matcher admits. Without a fix, **every LAN-only admin UI is exposed to the internet.** Both
   layers live in the repo: the SNI allowlist `map` on the VPS, and `not remote_ip 100.64.0.12`
   in every `lan_only` snippet of the Caddyfile. Full explanation:
   [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Security.
6. **Harden.** `sudo systemctl mask --now rpcbind rpcbind.socket` (public `:111`).

## Verify

`gh workflow run edge-access-policy.yml` asserts both layers from outside and from the VPS
([runbook](edge-access-policy-probe.md)). By hand, from a machine outside the LAN:

```sh
# gray-cloud jellyfin through the real public door — expect a 2xx/3xx
curl -sk --resolve jellyfin.example.com:443:198.51.100.10 https://jellyfin.example.com \
  -o /dev/null -w "jellyfin -> %{http_code}\n"

# LAN-only names AND the orange-clouded public four are closed direct-to-origin — expect 000
for d in komodo radarr files auth; do
  curl -sk --resolve $d.example.com:443:198.51.100.10 https://$d.example.com \
    -o /dev/null -w "$d -> %{http_code}\n"; done
```

`auth`/`files`/`immich`/`mealie` answer only through Cloudflare (the `geo $cf_edge` gate), so check
those in a browser.

## Follow-ups / alternatives

- **The VPS tailnet IP is load-bearing** — for the `not remote_ip` exclusion and the
  `proxy_protocol { allow … }` in the Caddyfile, and `VPS_TAILNET_IP` in the probe. If it ever
  changes, update all of them ([micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Security).
- **Removing the origin IP** for the orange-clouded names with a Cloudflare Tunnel is designed but
  not built — [cloudflare-tunnel-cutover](cloudflare-tunnel-cutover.md).
