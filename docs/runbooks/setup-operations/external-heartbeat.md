# Runbook: External dead-man's switch (healthchecks.io)

## Why

Every alerting path in this estate runs *inside* the estate: Kuma watches services, the health
check runs on the NAS runner, the backup crons e-mail through TrueNAS. All of it shares one
premise — that something here is still alive to notice.

Moving Kuma off the ingress VPS
([STR-2](../../architecture-review-2026-08-20.md#str-2--the-external-watchdog-is-inside-what-it-watches))
fixed the narrow case where the watchdog died with the thing it watched. It did not fix the
general one: **a watchdog you operate cannot report that everything you operate is down.** Both
Oracle instances and the NAS are the same person, the same accounts, the same payment method.

healthchecks.io closes that. Each host pings a check on a schedule; if the pings stop, an alerter
**not operated here** raises the alarm. A power cut, a suspended Oracle tenancy, an expired card,
a dead uplink — all become visible.

## Layout: one check per failure domain

| Check | Host | Guard container |
| --- | --- | --- |
| `nas` | TrueNAS, `192.168.178.111` | `caddy` |
| `a1` | Ampere A1, `198.51.100.20` | `matrix-synapse` |
| `micro` | AMD micro (public ingress), `198.51.100.10` | `micro-vps-ingress-nginx-1` |

Three checks rather than one, because the three hosts fail independently and a single combined
heartbeat would go silent for any of them without saying which.

## What the ping means

[`scripts/healthchecks-ping.sh`](../../../scripts/healthchecks-ping.sh) does more than prove the
host has power. It reads a **guard container** name and:

- guard running → ping the check's normal URL (green)
- guard **not** running → ping `<url>/fail`, turning the check red **immediately** rather than
  waiting out the grace period

That distinction matters: a host that is up but not serving is worse than one that is off, because
a plain liveness ping would keep reporting green through it.

The ping body carries the reason (`guard container 'caddy' running`), so the healthchecks.io
event log says *why*, not just *when*.

> **The guard name is host-side config and no deploy updates it.** When the container that
> constitutes "this host is doing its job" is replaced, the guard has to be rewritten by hand or
> the check goes red on the next cron tick — which is exactly what happened at the
> [Caddy cutover](caddy-migration.md), where the `nas` guard still named `npmplus`. It is one
> line, and it belongs in the same change as the swap:
>
> ```sh
> sudo sh -c 'echo caddy > /root/.config/healthchecks-guard.container'
> sudo /usr/local/bin/healthchecks-ping.sh    # -> "ok — guard container 'caddy' running"
> ```
>
> The same applies in reverse: **rolling back to NPMplus means flipping the guard back**, or the
> `nas` check pages you through a deliberate rollback.

## Host-side config (never in git)

The ping URL is effectively a credential — anyone holding it can keep a dead host looking alive —
so it follows the same rule as the Kuma push URLs: **host file, not the repo.**

| Path | Contents | Mode |
| --- | --- | --- |
| `/root/.config/healthchecks-ping.url` | the check's ping URL | `600 root:root` |
| `/root/.config/healthchecks-guard.container` | one container name | `600 root:root` |

Both paths are overridable with `HC_URL_FILE` / `HC_GUARD_FILE` for testing. Omit the guard file
and the script degrades to a plain liveness ping.

## Schedule

Every **minute** on all three hosts.

- **NAS** — TrueNAS cron, running the script out of the auto-pulled clone
  (`/mnt/apps/scripts/nas/scripts/healthchecks-ping.sh`), so a push to `main` updates it.
- **A1 and micro** — `/etc/cron.d/healthchecks-ping`, running
  `/usr/local/bin/healthchecks-ping.sh`. These hosts have **no repo clone**, so the script is
  installed by hand; re-copy it after changing it:

  ```sh
  scp -i secrets/ssh/ssh-a1-key.key -P 2222 scripts/healthchecks-ping.sh ubuntu@198.51.100.20:/tmp/
  ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20 \
    'sudo install -m 755 -o root -g root /tmp/healthchecks-ping.sh /usr/local/bin/ && rm /tmp/healthchecks-ping.sh'
  ```

Set **period 1 min and grace 2 min** in the healthchecks.io UI to match. A check then goes late
roughly three minutes after the last successful ping, so it tolerates one missed run but not two.

> **That is a deliberately tight setting** — it detects an outage in about three minutes, at the
> cost of alerting on a blip that a longer grace would have absorbed (a reboot, a brief uplink
> stall, an Oracle live-migration). If it turns out noisy, widen the **grace** rather than the
> period: the ping cadence is what bounds detection time.
>
> Both VPS hosts reboot on their own after a kernel or libc update
> ([OS updates](os-updates.md)). The test reboots on 2026-09-16 missed one ping on the
> micro and none on the A1, which stays inside the grace.

The script's retry budget is sized for this cadence — `-m 10 --retry 2 --retry-delay 3`, about 23
seconds worst case, so a slow ping cannot overrun into the next minute's run.

Configure the notification channel in the same UI — e-mail is the obvious one, but it must go
somewhere **not** dependent on this estate.

**Period and grace cannot be set from here.** They are project settings behind healthchecks.io's
Management API key; the ping URLs alone do not grant it. Either set them in the UI, or put the
project API key on the NAS and they can be scripted.

## Testing it

Run it by hand on any host:

```sh
sudo /usr/local/bin/healthchecks-ping.sh          # A1 / micro
sudo /bin/sh /mnt/apps/scripts/nas/scripts/healthchecks-ping.sh   # NAS
```

To prove the red path works, point the guard at a container that does not exist, run it, and watch
the check flip red — then put the real name back and run it again:

```sh
sudo sh -c 'echo definitely-not-a-container > /root/.config/healthchecks-guard.container'
sudo /usr/local/bin/healthchecks-ping.sh     # -> "fail — guard container ... is not running"
sudo sh -c 'echo matrix-synapse > /root/.config/healthchecks-guard.container'
sudo /usr/local/bin/healthchecks-ping.sh     # -> "ok"
```

## Rotating a ping URL

Create a new check in healthchecks.io, then replace the URL file on that host and run the script
once to confirm. Nothing in git changes.

## Common failures

- **`healthchecks-ping: no URL at /root/.config/healthchecks-ping.url`** — the file is missing or
  not readable as root.
- **`could not reach healthchecks.io`** — the host has no outbound internet. Exits non-zero, so
  cron mail (where configured) surfaces it; the check going silent is the real alarm.
- **Check silent but host is fine** — cron is not running the job. `systemctl status cron` on the
  VPS hosts; `midclt call cronjob.query` on the NAS.
- **Check green while the service is broken** — the guard container is running but unhealthy. The
  guard is a liveness signal, not a health gate; Kuma and the nightly health check cover depth.

## Last updated

2026-08-21
