# Dual Uptime Kuma Monitoring Strategy

Two Kuma instances, split by what each can see:

1. **A1 Kuma (External)**: Alerts you if your home loses power, internet, or the Tailscale VPN drops, or the public edge breaks. It lives on the **Ampere A1**, not the ingress VPS — a watchdog on the ingress host cannot report that the ingress host died.
2. **NAS Kuma (Internal)**: Alerts you if specific Docker containers, databases, or local proxy routes fail on the NAS.

Neither can report that *everything* here is down — that is [healthchecks.io](external-heartbeat.md).

---

## 1. A1 Kuma Setup (The External Watchdog)
**Location:** Oracle Ampere A1 (`a1-matrix`) — [service doc](../../services/a1-vps-kuma.md)
**Access:** `http://100.64.0.13:3001` (via Tailscale)
**Goal:** Verify that the NAS is online and public internet ingress routing is functioning.

### A. Infrastructure & Connectivity
These monitors verify the connection between the public internet/VPS and your home NAS.

| Monitor Name | Type | Target | Expected Status | Notes |
|---|---|---|---|---|
| **NAS Tailnet Ping** | Ping | `100.64.0.11` | Up | Validates that the NAS Tailscale node is online. If this drops, the NAS is offline or home internet is dead. |
| **NAS LAN Ping** | Ping | `192.168.178.111` | Up | Validates the Tailscale Subnet Router is functioning correctly and the NAS host is responsive. |

### B. Public-Facing Services (End-to-End)
These monitors verify that traffic properly routes from the Internet -> Cloudflare -> VPS nginx -> Tailscale -> NAS Caddy `:8443` -> Container. All five public names belong here: the [edge access policy probe](edge-access-policy-probe.md) cannot check the liveness of the four orange-clouded ones from a GitHub runner, and relies on this instance for it.

| Monitor Name | Type | Target URL | Expected Status | Notes |
|---|---|---|---|---|
| **Authentik (SSO)** | HTTP(s) | `https://auth.example.com/` | 200 OK | Critical. If Authentik is down, you cannot log into anything else. |
| **Files** | HTTP(s) | `https://files.example.com/` | 200 OK | Quantum serves its SPA unauthenticated and redirects to Authentik from the browser, so this is a plain 200 since the 2026-09-09 cutover. |
| **Immich API** | HTTP(s) | `https://immich.example.com/api/server/ping` | 200 OK | Ping the API endpoint directly to avoid UI loading overhead. The old `/api/server-info/ping` path returns `404` on current Immich — a monitor still on it is permanently red. |
| **Mealie** | HTTP(s) | `https://mealie.example.com/` | 200 OK | |
| **Jellyfin** | HTTP(s) | `https://jellyfin.example.com/health` | 200 OK | Gray-cloud, so this one reaches the VPS directly rather than through Cloudflare. |

### C. Heartbeats (Push)
Push monitors that the NAS jobs ping on success, so a job that silently stops running is itself an alert. Interval a little over the job's own cadence.

| Monitor Name | Pinged by | Host file with the push URL |
|---|---|---|
| **pg-dump** | [`pg-dump-backup.sh`](../../../scripts/pg-dump-backup.sh), daily 02:30 | `/root/.config/pg-dump-kuma-push.url` |
| **config-email** | [`truenas-config-email.sh`](../../../scripts/truenas-config-email.sh), daily 02:15 | `/root/.config/config-email-kuma-push.url` |
| **a1-file-backup** | [`a1-file-backup.sh`](../../../scripts/a1-file-backup.sh), daily 02:00 | `/root/.config/a1-file-backup-kuma-push.url` |
| **docker-image-prune** *(optional)* | [`docker-image-prune.sh`](../../../scripts/docker-image-prune.sh), weekly | `/root/.config/docker-image-prune-kuma-push.url` |

Setup: [restore-drill → Silent-failure heartbeats](../backup-restore/restore-drill.md#silent-failure-heartbeats).

> **Notification Setup**: In A1 Kuma, set up push notifications (e.g. to a mobile app, Discord, or Telegram) so you receive an alert on your phone immediately if the house loses power.

---

## 2. NAS Kuma Setup (The Internal Monitor)
**Location:** TrueNAS Local — [service doc](../../services/kuma.md)
**Access:** `https://kuma.example.com` (via LAN/Tailscale)
**Goal:** Deep dive into internal service health. If the A1 instance alerts you, you check here to find out *what* specifically broke.

### A. Core Infrastructure (TCP / Ping)
Check the core components that other services depend on.

| Monitor Name | Type | Target | Expected Status | Notes |
|---|---|---|---|---|
| **Caddy (HTTPS)** | TCP Port | `192.168.178.111 : 443` | Up | The edge proxy for every LAN and tailnet name. |
| **Caddy (HTTP)** | TCP Port | `192.168.178.111 : 80` | Up | HTTP→HTTPS redirects. |
| **AdGuard DNS** | DNS | `adguard : 53` | Returns an IP | Test resolving a domain (e.g., `google.com`). Kuma connects to AdGuard directly via the `proxy_adguard` network to bypass Docker UDP Hairpin NAT. |

> Before the 2026-09-07 Caddy cutover this section monitored NPMplus on `:80` and its admin UI on
> `:81`. Nothing listens on `:81` any more — delete that monitor if it still exists.

### B. Web Interfaces (LAN-Only Apps)
Kuma on the NAS uses AdGuard's DNS to resolve `*.example.com` to the local LAN IP (`192.168.178.111`), so these validate that Caddy routes the local names — and, because Kuma's requests hairpin in as `172.16.25.1`, that Caddy's `@lan` matcher still admits that address.

| Monitor Name | Type | Target URL | Expected Status | Notes |
|---|---|---|---|---|
| **AdGuard Web UI** | HTTP(s) | `https://adguard.example.com` | 200 OK | |
| **Beszel Hub** | HTTP(s) | `http://100.64.0.11:8090` | 200 OK | Monitor the direct tailnet binding. |
| **Paperless-ngx** | HTTP(s) | `https://paperless.example.com` | 200 OK | |
| **Grafana** | HTTP(s) | `https://grafana.example.com/api/health` | 200 OK | |

### C. Media & Download Stack (*arrs)
Add monitors for your entertainment stack to catch failing containers or VPN routing issues.

| Monitor Name | Type | Target URL | Expected Status | Notes |
|---|---|---|---|---|
| **Jellyfin** | HTTP(s) | `https://jellyfin.example.com/health` | 200 OK | Uses Jellyfin's built-in healthcheck endpoint. |
| **Seerr** | HTTP(s) | `https://seerr.example.com` | 200 OK | |
| **Sonarr** | HTTP(s) | `https://sonarr.example.com/ping` | 200 OK | Uses the standard *arr `/ping` endpoint. |
| **Radarr** | HTTP(s) | `https://radarr.example.com/ping` | 200 OK | |
| **Prowlarr** | HTTP(s) | `https://prowlarr.example.com/ping` | 200 OK | |
| **qBittorrent** | HTTP(s) | `https://qbittorrent.example.com` | 200 OK | |
| **Sabnzbd** | HTTP(s) | `https://sabnzbd.example.com` | 200 OK | |

### D. Certificate expiry — the `*.example.com` wildcard

| Monitor Name | Type | Target URL | Settings | Notes |
|---|---|---|---|---|
| **Caddy wildcard cert (\*.example.com)** | HTTP(s) | `https://auth.example.com/` | **Certificate Expiry Notification ON**, interval 3600s, accepted codes `200-299`,`302` | The only expiry alarm that exists. |

This monitor's job is the certificate, not the page. Caddy manages one
`*.example.com` wildcard over Let's Encrypt DNS-01 ([caddy.md](../../services/caddy.md)) and
there is **no ACME contact address**, so nothing e-mails you about a failing renewal. Kuma's TLS
notification (`tlsExpiryNotifyDays`, `[7,14,21]`) is the whole alerting path.

The thresholds are deliberately well below the renewal point: Caddy renews at roughly a third of
the lifetime remaining, ~30 days on a 90-day certificate, so a healthy renewal never trips 21
days. **The alarm firing means renewal has already failed**, with about three weeks of warning.
No soak proves this — a freshly issued certificate does not renew for ~60 days — which is why the
check exists rather than the confidence.

Verify it is really watching the cert and not just the page:

```bash
sudo docker exec uptime-kuma sqlite3 /app/data/kuma.db \
  "select json_extract(info_json,'$.certInfo.validFor'), json_extract(info_json,'$.certInfo.daysRemaining')
   from monitor_tls_info where monitor_id=(select id from monitor where name like 'Caddy wildcard cert%');"
```

Expect `["*.example.com"]` and a day count. An empty `monitor_tls_info` row means the monitor is
running but Kuma never saw a certificate — check the URL is `https://`.

### E. Torrent VPN Health
Kuma is on neither `media_net` nor `proxy_downloads`, so it cannot reach `gluetun` by name. The qBittorrent and SABnzbd HTTP monitors above catch a `downloads` stack that is down; a VPN tunnel that dropped while the containers keep running shows up in gluetun's own healthcheck (`unhealthy`), which the [deploy gate](portainer-webhook-deploy.md) and the nightly health check read.

> **Notification Setup**: For NAS Kuma, you might prefer a lower-urgency notification channel (like e-mail) so you aren't woken up if a *arr container temporarily restarts.
