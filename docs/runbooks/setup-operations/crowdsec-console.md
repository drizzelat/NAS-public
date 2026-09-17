# Runbook: Enroll CrowdSec in the Console (blocked-traffic dashboard)

## Why

The `caddy` stack's CrowdSec container detects attacks locally, but the only local view of that is
`cscli` on the command line. The **CrowdSec Console** (`app.crowdsec.net`, free tier) is a hosted
dashboard for the same data: alerts, active decisions, which scenarios fired, per-IP detail and
history.

Enrollment is one command plus a click. Nothing is installed locally and no port is opened — the
CrowdSec agent makes an **outbound** connection to the Console API.

> **This is a dashboard, not enforcement.** Enforcement is the
> [Caddy bouncer](crowdsec-bouncer.md#the-caddy-bouncer), which **is** enabled on this NAS, so the
> Console shows real blocks. On a rebuild without the bouncer it shows only what CrowdSec *would*
> have blocked, while every request is still served.

## What gets shared

Enrollment sends alert metadata to CrowdSec's cloud: attacker IPs, the scenarios they tripped,
timestamps, and your machine list. It does **not** send your access log, your proxy config, or
the contents of requests. Local whitelists still apply first, so the ranges listed in
[crowdsec-bouncer.md](crowdsec-bouncer.md#the-vps-ingress-ip-gets-banned) (`192.168.0.0/16`,
`10.0.0.0/8`, `172.16.0.0/12` and the tailnet `100.64.0.0/10`) never generate alerts and therefore
never leave the NAS.

## One-time setup

The enrollment key is a **secret — do not commit it.**

1. Create a free account at <https://app.crowdsec.net>. The Console shows an **enrollment key**
   (Security Engines → add/enroll an engine) inside a ready-made `cscli console enroll …` command.
   The key belongs to the **account**, not to a machine, so the same key enrolls further engines.

   Do not confuse it with the other CrowdSec keys:

   | Key | Made by | Used for | Where it lives |
   | --- | ------- | -------- | -------------- |
   | **Enrollment key** | CrowdSec Console (cloud) | `cscli console enroll`, links this engine to your account | Console UI only; never in the repo |
   | Bouncer API key | `cscli bouncers add caddy-bouncer` (local) | Caddy bouncer → LAPI and AppSec | `CROWDSEC_API_KEY` on the `caddy` stack, held in the age vault |
   | CAPI machine credentials | created at first start | pulling the community blocklist | `/etc/crowdsec/online_api_credentials.yaml` (config volume) |
   | CTI API key | Console, separately | querying the threat-intel API | not used here |

2. Enroll the local LAPI:

   ```bash
   docker exec crowdsec cscli console enroll --name nas <enrollment-key>
   ```

   `--name` sets the display name in the Console; without it the engine shows up under its
   container ID. Other flags: `--tags`, `--overwrite` (re-enroll an enrolled engine), and
   `-e/--enable` / `-d/--disable` for console options.

   > **Leave decision management (`console_management`) off.** It lets the Console push decisions
   > *down* into this engine, so the cloud side could ban IPs at your front door. It is inactive
   > here anyway, because it needs a SECOPS or ENTERPRISE plan (`cscli console status` says so); if
   > the plan ever changes, turn it on deliberately, not by pasting a command that includes it.

   Over SSH, `truenas_admin` has passwordless sudo, so `sudo -n docker exec crowdsec cscli …`
   works. There is no UI console for it any more; Portainer's went with it on 2026-09-17.

3. **Accept the instance** in the Console UI (Security Engines → pending enrollment). Nothing
   appears until you do.

4. Restart only the `crowdsec` container so it picks up the console credentials:
   `sudo -n docker restart crowdsec`.

   > Caddy keeps serving during the restart: `appsec_fail_open` in the Caddyfile lets requests
   > through while AppSec is unreachable. Restarting the whole `caddy` stack instead would take
   > the front door down with it.

## Verify

```bash
docker exec crowdsec cscli console status     # enrolled options should be enabled
docker exec crowdsec cscli alerts list        # local alerts — the same ones the Console shows
```

The Console's Security Engines page should list the instance as connected. Alerts take a few
minutes to first appear; if there is genuinely no attack traffic yet, the list being empty is not a
fault — confirm detection itself is alive with `cscli metrics show acquisition` ("Lines parsed"
must be non-zero, see [crowdsec-bouncer.md](crowdsec-bouncer.md) → The Caddy bouncer).

## Notes

- **Console enrollment does not affect local Prometheus.** CrowdSec still exposes metrics on
  `:6060`, which the [observability stack](../../services/observability.md) scrapes for its
  *CrowdSec — Security* dashboard. That needs `prometheus.listen_addr` set to `0.0.0.0` in
  `/mnt/apps/npm/crowdsec/config/config.yaml` — the default `127.0.0.1` is unreachable from another
  container.
- Enrollment state lives in `/mnt/apps/npm/crowdsec/config` (a mounted volume), so it survives
  container recreation and image pulls, and is covered by the existing backup of that path.
- To undo: `cscli console enroll --help` has no unenroll; remove the instance from the Console UI
  and delete the console credentials file under `/etc/crowdsec` in the container.
- Traffic volume (as opposed to blocked traffic) is **not** in the Console. It is Grafana at
  `grafana.example.com` ([observability.md](../../services/observability.md)), built from
  `/mnt/apps/caddy/logs/access.log`; GoAccess, which NPMplus fed, went with the Caddy cutover.
