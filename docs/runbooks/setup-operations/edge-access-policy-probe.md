# Runbook: Edge access policy probe

## Why

Two independent layers keep admin hostnames off the public internet, and **neither is proven by
being in git**: the SNI allowlist only takes effect once Komodo deploys it to the VPS, and
Caddy's `@lan` exclusion only holds while the running Caddyfile is the committed one and every
LAN-only vhost still imports `lan_only`. Until the 2026-09-07 Caddy cutover the second layer was
NPM Access List UI state that nothing reviewed —
[GAP-1](../../architecture-review-2026-08-20.md#gap-1--npm-and-authentik-config-is-click-ops)
called it the most dangerous configuration in the estate, and a proxy host deleted by hand during
[SVC-3](../../architecture-review-2026-08-20.md#svc-3--delete-scrutiny) showed the drift is real.

[`edge-access-policy.yml`](../../../.github/workflows/edge-access-policy.yml) turns both layers
into an assertion. It runs **every 6 hours**, fired by a host cron rather than by GitHub's own
`schedule:` — see [On-time trigger](#on-time-trigger) for why. On a timer rather than on PRs,
because the drift it exists for happens outside a commit: an undeployed stack, a Caddyfile the
clone never reloaded, a DNS change at Cloudflare. A red run sends the usual
GitHub failure e-mail.

## The two layers mask each other

This is the whole reason there are two jobs.

| | Layer 1 — VPS SNI allowlist | Layer 2 — Caddy `@lan` exclusion |
| --- | --- | --- |
| Where | [`stacks/micro-vps-ingress/`](../../../stacks/micro-vps-ingress/) `configs:` block | [`stacks/caddy/Caddyfile`](../../../stacks/caddy/Caddyfile), the `lan_only*` snippets |
| Rule | `map "$cf_edge:$ssl_preread_server_name"` → only `auth`/`files`/`immich`/`jellyfin`/`mealie` (the first four only from Cloudflare), `default ""` | `remote_ip 192.168.178.0/24 172.16.25.1 100.64.0.0/10` **and** `not remote_ip 100.64.0.12`, else `abort` |
| Observable from | the public internet | the VPS tailnet IP only |

With Layer 1 healthy an unlisted hostname never reaches Caddy, so **Layer 2's answer is invisible
from outside** — you cannot test it through the front door. And Layer 2 only ever sees traffic
the VPS forwarded, so it cannot tell you whether Layer 1 is doing its job. Each job below tests
exactly one of them.

### Job `sni-allowlist` — Layer 1, from a GitHub-hosted runner

Forces the public path with `curl --resolve`, the same shape as the diagnostic in
[micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Common failures, but aimed at the
**VPS public IP** rather than the Cloudflare anycast IP.

| Case | Expected | Meaning |
| --- | --- | --- |
| LAN-only host | curl exit **35** | unlisted SNI hit `proxy_pass ""`; the VPS closed the connection before TLS completed |
| Orange-clouded host (`auth`/`files`/`immich`/`mealie`) | curl exit **35** | listed, but only under the Cloudflare half of the `map` key — and this runner is not Cloudflare |
| `jellyfin` (gray-cloud) | `200`/`3xx` | the name is in the `map` for any source and the whole path to Caddy works |
| every host | A record is Cloudflare's, except `jellyfin` | the orange cloud is still on |

**Anything other than curl 35 on a blocked host is a failure, not a milder pass.** A `403`, or a
`444`-shaped drop (curl 52/56), means TLS completed and the NAS edge answered — Layer 1 has failed
open (the blind-forward regression) and only the `@lan` exclusion is still holding. A `200`/`3xx` means both
layers are gone.

**Curl 35 on an orange-clouded host is the pass, not a failure.** Since the Cloudflare-only gate
landed, the four orange-clouded names are forwarded only when the peer is a Cloudflare edge
address, so a runner reaching them directly would mean the gate is off and Cloudflare can be
bypassed — see [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Layer 1b. The mirror
failure now reads the other way: `200`/`3xx` on one of those four is the alarm.

The live half is not decoration: without it, a probe that only checks denies goes green when the
entire edge is down. `jellyfin` carries it here — gray-cloud, so it must answer from any source,
and curl 35 on it means someone added or moved a service without its `map` entry. Liveness for the
other four cannot be asserted from a runner at all (direct is now forbidden, and through Cloudflare
the runner gets a managed challenge), so **Uptime Kuma owns it**: it probes all five through
Cloudflare from the A1 every ~60 s, which is a tighter loop than this 6-hourly job anyway.

> **Why not through Cloudflare.** The obvious probe resolves the Cloudflare IP and asserts the
> **`525`** an ordinary client gets, and that is exactly what a browser on a home connection sees.
> A GitHub-hosted runner does not: Cloudflare serves its datacenter IP a **managed challenge**
> (`HTTP 403`, `Cf-Mitigated: challenge`, a JS interstitial curl cannot solve) on *every* name in
> the zone, public ones included. It is also reputation-dependent, so it would flap. Going straight
> to the VPS removes Cloudflare from the assertion and tests the SNI allowlist itself — which is
> stronger, since the `525` was only ever an inference about what the VPS did. Restoring the
> Cloudflare leg would need a WAF **Skip** rule keyed on a secret header, i.e. more click-ops in
> the layer this workflow exists to de-click-ops.
>
> What that leg *did* give us is kept as a direct assertion: the job resolves each name over DoH
> and requires the A record to be a Cloudflare address — the VPS public IP for `jellyfin`, which is
> DNS-only (video streaming, ToS §2.8), and a Cloudflare address for everything else. Grey-clouding
> an admin host would expose the origin IP and drop Cloudflare's TLS/DDoS layer; orange-clouding
> `jellyfin` would break streaming. Both now fail the run.

### Job `edge-access-list` — Layer 2, from the ingress VPS

The rule under test is an **exclusion**: `@lan` admits `100.64.0.0/10` but must exclude
`100.64.0.12`, because the VPS forwards from an address inside that CGNAT range. Drop the
exclusion and every LAN-only admin UI is on the internet.

Caddy's public listener is `:8443`, wrapped in `proxy_protocol` with
`allow 100.64.0.12/32` and `fallback_policy reject`, so a plain `curl` is not parsed. The probe
sends a **PROXY v1 header** with `curl --haproxy-protocol --haproxy-clientip <ip>`; Caddy takes the
claimed address as the client IP — but only for connections that really come from the VPS, which is
what the wrapper's allow-list enforces. So the probe can put any client IP it likes in front of the
matcher and read back the verdict:

| Host | Claimed client | Expected | Proves |
| --- | --- | --- | --- |
| every LAN-only host | `100.64.0.12` | **deny** | the exclusion exists and applies to that host |
| `komodo` | `100.64.0.1` | allow | the tailnet range is still admitted — the matcher is not simply "deny all" |
| `komodo` | `192.168.178.50` | allow | the LAN range is still admitted |
| `komodo` | `203.0.113.10` | **deny** | an ordinary public client is caught |
| every public host | `203.0.113.10` | allow | Caddy is answering, so the denies above mean something |

One host carries the range cases because every LAN-only vhost imports the **same** `lan_only`
snippet — the per-host sweep is what catches a vhost that was written without it.

**A denied request reads as no HTTP response at all.** Under NPMplus that was `444` — a reset,
curl exit 56. Caddy's `abort` closes cleanly instead, curl exit 52. The job accepts either, and
also a plain `403`: a host that answers `403` has lost the drop but not the policy, which is a
cosmetic regression this probe should not go red for.

**Curl exit 52 is also accepted as denied.** It is the same "no HTTP response at all" outcome
reached by a clean close rather than a reset — what Caddy's `abort` does where nginx's `444`
resets. Accepting it is what lets the deny stay a drop rather than a fingerprintable `403` through
the [SVC-1](../../architecture-review-2026-08-20.md#svc-1--npmplus--caddy) migration; the failure
this assertion exists to catch, a `200`/`3xx`, is still caught. Curl exit **35** is different and
*is* a failure — the TLS handshake failed at Caddy's `:8443` listener, which means no site block
answers to that name any more.

## VPS setup (one time)

The probe runs on the VPS as a **forced command** under a dedicated unprivileged user, so the CI
key can do nothing except print probe results — no shell, no sudo, no port forwarding.

```sh
VPS='ubuntu@198.51.100.10'; PORT=2222; KEY=secrets/ssh/ssh-key-vps.key

# 1. Install the probe (same pattern as healthchecks-ping.sh — these hosts have no repo clone).
scp -i "$KEY" -P "$PORT" scripts/edge-access-probe.sh "$VPS:/tmp/"
ssh -i "$KEY" -p "$PORT" "$VPS" \
  'sudo install -m 755 -o root -g root /tmp/edge-access-probe.sh /usr/local/bin/ && rm /tmp/edge-access-probe.sh'

# 2. Unprivileged user. It needs a real shell — a forced command runs through it.
ssh -i "$KEY" -p "$PORT" "$VPS" \
  'sudo useradd --system --create-home --home-dir /home/edgeprobe --shell /bin/sh edgeprobe'

# 3. Pin the CI key to the probe and nothing else.
printf 'command="/usr/local/bin/edge-access-probe.sh",restrict %s\n' \
  "$(cat secrets/ssh/edge-probe_ed25519.pub)" > /tmp/edgeprobe_ak
scp -i "$KEY" -P "$PORT" /tmp/edgeprobe_ak "$VPS:/tmp/"
ssh -i "$KEY" -p "$PORT" "$VPS" \
  'sudo install -d -m 700 -o edgeprobe -g edgeprobe /home/edgeprobe/.ssh &&
   sudo install -m 600 -o edgeprobe -g edgeprobe /tmp/edgeprobe_ak /home/edgeprobe/.ssh/authorized_keys &&
   rm /tmp/edgeprobe_ak'
rm /tmp/edgeprobe_ak
```

`restrict` disables agent/port/X11 forwarding and PTY allocation; `command=` overrides whatever
the client asks for. Verify the key really is fenced in:

```sh
ssh -i secrets/ssh/edge-probe_ed25519 -p 2222 edgeprobe@198.51.100.10 'id'   # runs the probe, not id
```

**Re-install the probe after every change to `scripts/edge-access-probe.sh`.** The job asserts the
running copy's `sha256` against the repo copy and fails if they differ — a hand-edited VPS copy is
exactly the drift this workflow exists to catch.

## On-time trigger

GitHub's `schedule:` cron is **best-effort**, and for this repo it has stopped being usable:
measured over 2026-08/09 the delivery delay ran **2.5–5.5 h** at every slot, and `renovate.yml`'s
hourly cron collapsed from 24 runs/day to 2–5 from 2026-08-27 on. This probe was hit the same way
— `17 */6 * * *` is four slots a day, and over the 19 h after the Caddy cutover it produced
**three** runs, not four, at 12:34Z, 21:31Z and 04:37Z rather than 12:17/18:17/00:17/06:17.

That is worse here than a late merge. This workflow is the estate's **only** machine-checked
assertion that admin hostnames are unreachable from the internet, and the drift it guards happens
outside git at a time nobody chose. A drift detector on a trigger the platform drops is not a
drift detector — it is a detector that agrees with you most days.

So the primary trigger is a TrueNAS cron hitting `workflow_dispatch`, the same pattern (and the
same token) as the [Renovate on-time trigger](renovate-trigger.md) and the
[health check](nas-health-check.md#on-time-trigger):

```
TrueNAS cron :17 every 6h Vienna ─▶ edge-probe-trigger.sh ─▶ POST /workflows/edge-access-policy.yml/dispatches
GitHub cron 08:17 UTC            ─▶ same workflow, fallback trigger only
```

The host clock is Central European (`timedatectl` reports `Europe/Berlin`, the same offset and DST
rules as the Vienna times this repo's docs quote), so the cron follows DST on its own; no UTC
summer/winter pair.

### The fallback, and why it is guarded

Unlike the health check's, this fallback **is** a NAS-down fallback in part: both jobs run on
`ubuntu-latest`, not on the self-hosted runner, so GitHub can still execute them when the NAS is
gone. What it cannot do then is dispatch itself — so a NAS outage silences the primary trigger and
the fallback is what still fires. Note the consequence: during a *deliberate* NAS outage (a reboot,
say) a fallback run will go red, correctly and unhelpfully. Expect it.

The fallback must not duplicate the host cron's four daily runs. The `guard` job checks this
workflow's own run list and sets `skip=true` when a `workflow_dispatch` run already reached a
conclusion on the same UTC day; both probe jobs `needs: guard` and are skipped on that output. When
no dispatch landed, it runs **and** logs a `::warning::` naming the broken cron. It needs
`actions: read`, which is why the workflow grants it.

Its cron is `17 8 * * *` **UTC**, which is at least two hours clear of every host slot in both DST
offsets (host slots land at 22:17/04:17/10:17/16:17 UTC in summer, an hour later in winter), so the
guard never races the run it is checking for.

### Cron job (TrueNAS → System → Advanced → Cron Jobs, run as root)

| Schedule | Command |
| --- | --- |
| `17 0,6,12,18 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/edge-probe-trigger.sh` |

Same conventions as the other trigger crons: `user: root`, `enabled: true`, stdout and stderr
suppressed (the script logs to `/var/log/edge-probe-trigger.log`), invoked via `/bin/sh <path>`
because the repo is authored on Windows and the exec bit does not survive.

```sh
midclt call cronjob.create '{"description":"edge-access-policy on-time trigger",
  "command":"/bin/sh /mnt/apps/scripts/nas/scripts/edge-probe-trigger.sh",
  "user":"root","schedule":{"minute":"17","hour":"0,6,12,18","dom":"*","month":"*","dow":"*"},
  "enabled":true,"stdout":true,"stderr":true}'
```

The token is the existing fine-grained PAT at `/root/.config/renovate-trigger.token`
(**Actions: read+write** on `drizzelat/NAS` only) — already on the host for the Renovate and
health-check crons, no new secret. Setup and rotation:
[Renovate on-time trigger](renovate-trigger.md).

Verify a dispatch by hand:

```sh
sudo /bin/sh /mnt/apps/scripts/nas/scripts/edge-probe-trigger.sh
tail -2 /var/log/edge-probe-trigger.log
```

That proves the script and the token. To prove the **cron** as well — that the middleware really
executes the entry, which is the half a hand-run cannot show — run the job through it:

```sh
sudo midclt call -j cronjob.run <id>     # id from: midclt call cronjob.query
```

TrueNAS 25.04 does not materialise these into `/etc/cron.d` or root's crontab (`crontab -l` reports
none), so grepping for the entry proves nothing; `cronjob.run` is the check that does.

## Credentials

| What | Where |
| --- | --- |
| `VPS_PROBE_SSH_KEY` | GitHub Actions secret — `gh secret set VPS_PROBE_SSH_KEY < secrets/ssh/edge-probe_ed25519` |
| private key | age vault, `secrets.enc/ssh/edge-probe_ed25519.age` ([secret-sync](secret-sync.md)) |
| VPS host key | pinned inline in the workflow — an unauthenticated origin could otherwise fake a passing probe |

The key is deliberately **not** `ssh-key-vps.key`: that one is `ubuntu` with passwordless `sudo`
on the public front door, and CI has no business holding it.

## Running it by hand

```sh
gh workflow run edge-access-policy.yml
gh run watch
```

Layer 1 alone, the way the job does it — straight at the VPS, expect curl exit 35:

```sh
curl -s --http1.1 --resolve kuma.example.com:443:198.51.100.10 https://kuma.example.com/ \
  -o /dev/null -w '%{http_code}\n'; echo "curl exit $?"
```

Through Cloudflare, from a machine Cloudflare does not challenge — expect `525`. This is the
diagnostic in the service doc and what a real client sees:

```sh
cf=$(dig +short @1.1.1.1 kuma.example.com A | head -1)
curl -s --http1.1 --resolve kuma.example.com:443:$cf https://kuma.example.com/ -o /dev/null -w '%{http_code}\n'
```

Layer 2 alone, from the VPS:

```sh
printf 'komodo 100.64.0.12\nkomodo 100.64.0.1\n' \
  | ssh -i secrets/ssh/ssh-key-vps.key -p 2222 ubuntu@198.51.100.10 'sh /usr/local/bin/edge-access-probe.sh'
```

## When it goes red

| Symptom | Cause | Fix |
| --- | --- | --- |
| blocked hosts return `403` or curl 52/56, public hosts fine | Layer 1 failed open — VPS is blind-forwarding | redeploy `stacks/micro-vps-ingress` (fire its webhook); check the live config per [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Common failures |
| blocked hosts return `200`/`3xx` | **both layers are down** — treat as an incident | as above, *and* check that host's vhost still imports `lan_only` |
| every host, both jobs, curl 7/28/35 | the VPS or its nginx is down | [micro-vps-ingress.md](../../services/micro-vps-ingress.md) → Common failures |
| a public host returns curl 35 | its hostname is not in the SNI allowlist `map` | add it to [`stacks/micro-vps-ingress/`](../../../stacks/micro-vps-ingress/) and bump `config-rev` |
| `DNS is grey-cloud, expected orange` | the orange cloud was switched off for that name | re-enable the proxy in Cloudflare, or move the name into `GREY_CLOUD_HOSTS` if deliberate |
| a LAN-only host is allowed for `100.64.0.12` | the `not remote_ip 100.64.0.12` clause is gone from its snippet, or the vhost stopped importing `lan_only` | restore it in `stacks/caddy/Caddyfile` and push — the clone's pull reloads Caddy |
| **Layer 2** reports curl exit 35 on a LAN-only host | no Caddyfile site block for that name any more | intended? update `LAN_ONLY_HOSTS` in the workflow and [network.md](../../network.md). Otherwise restore the vhost |
| `probe on the VPS is not scripts/edge-access-probe.sh` | VPS copy drifted, or the repo copy changed without a re-install | re-run step 1 of VPS setup |
| `could not run the probe on the VPS` | key, user or forced command missing; VPS unreachable on `:2222` | re-run VPS setup; check the host is up |

## Adding or removing a host

The host lists are `env:` at the top of the workflow. A new **public** service needs its name in
`PUBLIC_HOSTS` (and in `CF_ONLY_HOSTS` or `DIRECT_PUBLIC_HOSTS`), a `map` entry in
[`stacks/micro-vps-ingress/`](../../../stacks/micro-vps-ingress/), and a Caddyfile vhost that does
not import `lan_only`. A new **LAN-only** service needs its name in `LAN_ONLY_HOSTS` and a vhost
that imports `lan_only`. Either way also update
[network.md](../../network.md) → Access control — the workflow and that list are meant to agree.
