# Runbook: Cert / DNS / proxy outage

Services unreachable by name, TLS errors, or "everything is down from the internet."
This covers the three failure domains in the request path and how to tell them apart fast.

## The request path (so you can localise the break)

```text
Client ──DNS──► name resolves ──► (public) Cloudflare → Oracle VPS → Tailscale ──► Caddy :8443 ──► app
                 │                  (LAN)    direct to Caddy :443 on the NAS ────────────────────►
                 ▼
     AdGuard (LAN clients)  /  public DNS → Cloudflare (orange-cloud) or the VPS IP (jellyfin)
```

Three independent things can break it:

1. **DNS** — the name doesn't resolve (AdGuard down for LAN; Cloudflare DNS for internet clients).
2. **Proxy / ingress** — Caddy is down, or the VPS→NAS Tailscale backhaul is down.
3. **TLS cert** — name resolves and Caddy answers, but the certificate is expired/invalid.

## Triage — narrow it in 60 seconds

```sh
# 1. Does the name resolve? (from a LAN client)
nslookup immich.example.com 192.168.178.111      # via AdGuard -> 192.168.178.111
nslookup immich.example.com 1.1.1.1              # bypass AdGuard -> Cloudflare addresses

# 2. Does Caddy answer on the LAN at all? (bypasses DNS + tunnel). --resolve keeps the SNI,
#    which Caddy needs: a bare-IP request fails the TLS handshake (curl exit 35).
curl -skI --resolve immich.example.com:443:192.168.178.111 https://immich.example.com

# 3. Cert validity
echo | openssl s_client -connect 192.168.178.111:443 -servername immich.example.com 2>/dev/null \
  | openssl x509 -noout -dates -subject
```

- Resolves only via `1.1.1.1`, not via AdGuard → **DNS / AdGuard** problem.
- Doesn't resolve anywhere (internet) → **Cloudflare DNS** problem.
- Resolves, but step 2 fails → **Caddy / ingress** problem.
- Steps 1–2 OK, browser shows cert error → **TLS cert** problem.

---

## A) DNS down (AdGuard)

AdGuard is the LAN resolver; if it's down, **LAN** name resolution fails for everything
(internet clients use public DNS and are unaffected).

1. Check/restart AdGuard — [adguard.md](../../services/adguard.md) → Operations.
2. **Stop-gap so the LAN keeps working:** point the router's DHCP DNS at the FritzBox or
   `1.1.1.1` until AdGuard is back, then revert.
3. If config is corrupt, restore `apps/adguard/config` from a snapshot ([adguard.md](../../services/adguard.md) → Restore).

> Internal `*.example.com` → NAS rewrites live in AdGuard (and Tailscale's split DNS points at
> it too). With AdGuard down and clients on `1.1.1.1`, names resolve publicly instead: the five
> **public** names still work the long way round (Cloudflare → VPS), but every **LAN-only** name is
> dropped by the VPS SNI allowlist (Cloudflare `525`). Until AdGuard is back, reach admin UIs with a
> hosts-file entry pointing the name at `192.168.178.111`. No admin UI keeps a host port any more.

## B) Proxy / ingress down (Caddy + VPS/Tailscale)

Caddy is the **single front door**; the Oracle VPS forwards public traffic to it over Tailscale.

1. **Caddy container** up? `sudo docker ps --filter name=caddy` on the NAS (Komodo's UI is behind Caddy itself). Restart if needed — [caddy.md](../../services/caddy.md) → Operations.
   - A restart briefly drops *all* proxied traffic (LAN included).
2. **Public down but LAN fine?** → the **VPS ingress or Tailscale backhaul** is broken (LAN clients
   hit Caddy directly and are unaffected). Check, in order ([micro-vps-ingress.md](../../services/micro-vps-ingress.md)):
   - NAS `tailscale` subnet-router stack up? (`sudo docker ps --filter name=tailscale`.) If it's down, the VPS can't
     reach Caddy.
   - SSH the VPS (`ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10`):
     `sudo tailscale status` (peer `nas` online?) and `sudo docker ps` (`micro-vps-ingress-nginx-1` up?).
   - Prove the tunnel path from the VPS: `curl -sk --resolve files.example.com:443:100.64.0.11
     https://files.example.com -o /dev/null -w '%{http_code}'` → `200` = backhaul OK, Caddy
     answering. The public path itself uses `:8443` — the second check in
     [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Common failures tests that listener.
   - VPS rebooted and nginx didn't relaunch → fire the `micro-vps-ingress` webhook, or use the
     break-glass copy in [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Operations.
3. **Legit LAN client getting an empty reply** (`curl` exit 52) → the `@lan` matcher rejected it.
   Check the client's source address as Caddy sees it in `/mnt/apps/caddy/logs/access.log`;
   containers hairpin in as `172.16.25.1`. Fix the matcher in
   [`stacks/caddy/Caddyfile`](../../../stacks/caddy/Caddyfile) and push
   ([network.md](../../network.md) → Access control).
4. **An IP unexpectedly blocked** → CrowdSec decision: `cscli decisions list` /
   `cscli decisions delete --ip <ip>` (in the crowdsec container). See
   [crowdsec-bouncer.md](../setup-operations/crowdsec-bouncer.md).
5. Config gone → Caddy's config is [`stacks/caddy/Caddyfile`](../../../stacks/caddy/Caddyfile) in
   git, so redeploy the stack. Only the certificates and the ACME account in `/mnt/apps/caddy/data`
   are state worth restoring from snapshot; losing them costs a re-issue, not an outage
   ([caddy.md](../../services/caddy.md) → Restore).

## C) TLS cert expired / renewal failing

Caddy terminates TLS for `*.example.com` via a Let's Encrypt **DNS-01** wildcard cert, renewed
automatically at ~30 days remaining. There is no UI — if the cert is near expiry, renewal has
already been failing for weeks, which is what the Kuma certificate-expiry monitor is for
([kuma-monitors.md](../setup-operations/kuma-monitors.md) → D).

1. `sudo docker logs caddy 2>&1 | grep -i acme` — the failure is almost always the Cloudflare
   token (`CLOUDFLARE_API_TOKEN`, the Komodo Variable `CADDY__CLOUDFLARE_API_TOKEN`) being expired or scoped wrong.
2. Re-issue the token at Cloudflare with **Zone → DNS → Edit** on `example.com`, update it in the
   vault and push it (`scripts/secrets.sh edit caddy` then `scripts/secrets.sh push caddy`), which
   redeploys `caddy`.
3. Force an attempt: `sudo docker restart caddy`. Caddy retries on start; re-check with the
   `openssl` command above.
4. If the cert store is corrupt, it lives in `/mnt/apps/caddy/data` (dataset `apps/caddy`) —
   restore from snapshot, or clear it and let Caddy re-issue.

## Knock-on effects to expect

- **Authentik down** → SSO logins for `files`, `immich`, `mealie` and public Jellyfin fail even
  though Caddy/DNS are fine, and `files` does not even start (its OIDC discovery is fatal at
  startup). Triage points at "app", not proxy. See [authentik.md](../../services/authentik.md).
- **Caddy down** → also takes out the LAN-only admin UIs (komodo, *arr, etc.) since
  direct host-port access is disabled by design ([network.md](../../network.md)). To deploy while
  Caddy is down, use the periphery's clone on the NAS ([komodo.md → Restart / redeploy](../../services/komodo.md#restart--redeploy)).

## Verify recovered

- [ ] Name resolves via AdGuard **and** public DNS.
- [ ] Public host loads over HTTPS with a valid cert (`https://immich.example.com`).
- [ ] An SSO app hands off to Authentik (`https://mealie.example.com` → *Login with authentik*).
- [ ] A LAN-only host loads on the LAN and gives a Cloudflare `525` from outside.
- [ ] `gh workflow run edge-access-policy.yml` comes back green.
- [ ] No firing alerts in Uptime Kuma.
