# Runbook: Email from services (own domain, hosted sender)

**Status: designed and decided, nothing built except the anti-spoofing lockdown (2026-09-21).**
No stack sends mail yet, and building it is **not scheduled**: this is a ready plan, to be started
only when someone decides to. Every question below was answered on 2026-09-21; the answers are in
[Decisions](#decisions-2026-09-21), and [Still to do](#still-to-do) is the work that follows from
them. The [service assessment](#service-assessment) and the [questions](#open-questions) stay for
their reasoning.

## Why

Today only TrueNAS sends mail here: its alerts and the daily
[config backup](../backup-restore/truenas-config-backup.md). It goes out through the owner's
personal Microsoft (Outlook) account using TrueNAS's built-in Outlook OAuth flow. That flow is the
only thing that works. Microsoft no longer accepts a plain password or app password for SMTP on
personal accounts, and every app in `stacks/` only speaks SMTP with a username and password. So
today Authentik cannot send a password-reset link, Immich cannot mail an album invitation, and
Paperless cannot reset a password.

A transactional mail provider, sending for our own domain, fixes that:

- **Plain SMTP everywhere.** A host, port 587, a username and a password or API key: every app
  supports it.
- **One credential per service.** A leaked one is revoked alone, and the sender address shows which
  one leaked.
- **Delivered, not junked.** The provider DKIM-signs as our domain, so the mail passes the domain's
  own DMARC policy instead of fighting it.
- **Not on the NAS.** The provider keeps delivering while the NAS is down, so A1 services (Kuma,
  Synapse) can use it without breaking the roadmap rule that A1 services must not depend on the NAS
  ([roadmap.md](../../roadmap.md#queue)).

**Not self-hosted.** The NAS sits behind CGNAT on a residential line. Receivers treat residential
ranges as spam sources, and Oracle blocks outbound port 25 by default. An own MTA would also be one
more internet-facing service to patch and watch. The provider does the delivery; we only submit to
it.

## What is live today: the domain sends and receives nothing

Added by hand in the Cloudflare UI on 2026-09-21. Cloudflare DNS is not managed from this repo, so
this table is the record:

| Type | Name | Content | Effect |
| ---- | ---- | ------- | ------ |
| TXT | `example.com` | `v=spf1 -all` | SPF: no server may send as the domain |
| TXT | `_dmarc.example.com` | `v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s` | Receivers reject mail that fails the check, for the domain and every subdomain |
| MX | `example.com` | `0 .` | Null MX (RFC 7505): the domain accepts no mail |
| TXT | `*._domainkey.example.com` | `v=DKIM1; p=` | Every DKIM selector is a revoked key, so a forged signature fails |

- **Subdomains are covered.** They have no `_dmarc` record of their own, so receivers fall back to
  the one above and apply `sp=reject`.
- **Nothing broke.** Nothing in the repo sent as the domain before; TrueNAS sends as the Outlook
  address.
- **The zone is not DNSSEC-signed** (no `DS` record). See [Q21](#dns-and-the-domain).

Check, from Cloudflare's own nameserver and a public resolver:

```sh
for ns in 1.1.1.1 dilbert.ns.cloudflare.com; do
  dig +short TXT example.com @"$ns"                 # "v=spf1 -all"
  dig +short TXT _dmarc.example.com @"$ns"          # "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"
  dig +short MX example.com @"$ns"                  # 0 .
  dig +short TXT test._domainkey.example.com @"$ns" # "v=DKIM1; p="  (any selector)
done
```

There must be exactly one SPF record and one DMARC record. Two of either is a `permerror`, which
receivers treat as having none.

## Design

```text
service ──SMTP :587 STARTTLS, its own credential──▶ provider ──signs DKIM d=notify.example.com──▶ recipient
                                                                                                     │
  recipient looks up:  <selector>._domainkey.notify.example.com   (Cloudflare, points at provider) │
                       _dmarc.notify.example.com → none → _dmarc.example.com (sp=reject)         │
                       DKIM aligned with From → DMARC pass ◀─────────────────────────────────────────┘
```

- **Nothing here may block a later household mailbox or receiving mail** ([Q7](#addressing),
  [Q33](#receiving)). Neither is wanted now; both must stay a matter of adding records.
- **Send from `notify.example.com`** ([Q1, Q2](#addressing)). The apex keeps all four lockdown
  records unchanged. A leaked credential can at worst send as `…@notify.example.com`, never as a
  personal-looking `…@example.com`. A future household mailbox on the apex then shares neither SPF
  nor reputation with service mail.
- **One address per app, named after it:** `authentik@notify.example.com`, display name
  `Authentik` ([Q3, Q4](#addressing)). No Reply-To: replies bounce until receiving exists, then get
  routed ([Q5](#addressing)).
- **Amazon SES in `eu-central-1` (Frankfurt)** as the hosted provider ([Q8](#provider-choice-q8)).
- **Submission only**, on 587 (STARTTLS) or 465 (implicit TLS). Never 25.
- **One credential per stack**, named after the stack at the provider, never reused.
  Env-configured apps keep it in the stack's vault env. UI-configured apps keep it in their own
  database ([Q26](#security)).
- **DMARC passes through DKIM.** `adkim=s` requires the signing domain to equal the From domain
  exactly: `d=notify.example.com` with From `…@notify.example.com`. SPF usually does not align,
  because the provider's bounce domain is the envelope sender, and it does not need to. DMARC needs
  only one of the two.
- **No open or click tracking.** Link rewriting breaks one-time links such as Authentik recovery,
  and it tells the provider who opened what ([Q16](#provider)).

## Decisions (2026-09-21)

**Wired, in this order:** Authentik, Immich, A1 Kuma, Beszel, Seerr, plus a daily canary (Q50).
**Not wired:** Paperless, Shelfmark, Mealie, Grafana, the NAS Kuma, Synapse, the arr apps,
downloads, CrowdSec and Komodo. **TrueNAS stays on Outlook OAuth**, as the independent path if the
provider fails.

| Q | Decision |
| - | -------- |
| 1 | `notify.example.com` |
| 2 | A subdomain; the apex is untouched |
| 3 | One address per app: `<app>@notify.example.com` |
| 4 | Display name = app name (`Authentik`, `Immich`) |
| 5 | No Reply-To. Replies bounce until receiving exists, then get routed |
| 6 | Each app's default template language (English) |
| 7 | No personal addresses now, but household mailboxes on the apex must stay possible: nothing here may block them |
| 8 | **Amazon SES, region `eu-central-1` (Frankfurt)**, picked from a comparison on 2026-09-21 ([Provider choice](#provider-choice-q8)) |
| 9 | One stream; only low-volume alerts go by mail |
| 10 | No attachment requirement: no app on the wired list sends attachments, and TrueNAS stays on OAuth |
| 11 | A credential pinned to one From address is nice-to-have, not required |
| 12 | Metadata kept about 30 days; message bodies as briefly as the provider allows. SES never stores bodies; the 30 days of metadata is a CloudWatch Logs group |
| 13 | 2FA on; the Outlook address as recovery; login and backup codes in Bitwarden |
| 14 | Fallback: TrueNAS stays on Outlook OAuth. Apps wait for a provider swap, which is a credential change |
| 15 | SMTP everywhere, no provider HTTP APIs |
| 16 | Open and click tracking off account-wide; required |
| 17 | Shared IP pool |
| 18 | Keep the apex null MX and `*._domainkey` revocation until an apex mailbox exists |
| 19 | DMARC reports through Cloudflare DMARC Management |
| 20 | No `_dmarc.notify`; inherit the apex `sp=reject`, and prove DKIM passes before wiring any app |
| 21 | Enable DNSSEC, step by step with a `dig` check before and after ([Still to do](#still-to-do)) |
| 22 | Auto-renew is on; renewal notices go to the Outlook address |
| 23 | This runbook is the record; the edge access policy probe asserts the records ([Still to do](#still-to-do)) |
| 24 | Prefer a provider with CNAME-delegated DKIM |
| 25 | Skip MTA-STS, TLS-RPT and BIMI until there is an inbox |
| 26 | Env-configured apps: the vault env. UI-configured apps: the app's database plus a Bitwarden copy |
| 27 | Email recovery for non-admins only; `akadmin` and `authentik Admins` are reset by hand |
| 28 | No emailed one-time codes as MFA |
| 29 | Authentik verifies addresses; the `mealie` provider then asserts `email_verified: true` and Mealie's `OIDC_REQUIRES_EMAIL_VERIFICATION` goes back on |
| 30 | Provider usage alert to the Outlook address, plus a per-credential rate limit where offered. SES has no per-credential limit: a CloudWatch alarm on the send count and an AWS Budget alert stand in |
| 31 | No mail for qBittorrent and SABnzbd |
| 32 | Note only: if container egress is ever restricted, keep 587 to the provider open |
| 33 | Receiving: maybe later, and it must stay possible |
| 34 | Forward or store: decided with receiving |
| 35 | Which name receives: decided with receiving. Sending on `notify` leaves the apex and every other name free |
| 36 | No mail consumption in Paperless |
| 37 | Account logins stay where they are. If moved later: never the registrar, Cloudflare or the mail provider |
| 38 | Authentik: recovery (non-admins), invitations, address verification, admin notifications |
| 39 | Immich: invitations and album updates on by default; users can opt out |
| 40 | Seerr: yes; the admin enters each user's address |
| 41 | No mail-in e-reader, so Shelfmark is not wired |
| 42 | Check where Beszel alerts go today, then add email for threshold alerts ([Still to do](#still-to-do)) |
| 43 | A1 Kuma: email next to Discord. That covers the off-NAS alert channel idea for now |
| 44 | TrueNAS stays on Outlook OAuth (Q14) |
| 45 | Grafana: not wired |
| 46 | Synapse: not wired |
| 47 | Komodo alerter: a separate task later, not part of this work |
| 48 | arr, downloads, CrowdSec: no mail |
| 49 | Add an SMTP line to the [new-service checklist](new-service.md) with the first wired app |
| 50 | Canary: a daily cron mails a healthchecks.io check through the provider; the check goes red when mail stops |
| 51 | Bounce and complaint notices to the Outlook address (SES: an SNS topic with an email subscription) |
| 52 | Each app's settings go in its `docs/services/<name>.md` env table; the assessment below gains a *Wired* column |
| 53 | After a major-version bump of a wired app, send its test mail again |
| 54 | Free tier; up to €5 a month if a needed feature costs money |
| 55 | Mirror rules go in the commit that first names the provider's domain |

### Still to do

1. ~~**Provider shortlist (Q8).**~~ Done 2026-09-21: Amazon SES, see [Provider choice](#provider-choice-q8).
2. **DNSSEC (Q21).** Enable in Cloudflare, add the `DS` record at the registrar, check with `dig`.
3. **DMARC Management (Q19).** Enable it in Cloudflare. It adds its own `rua=` address to the apex
   DMARC record; update the table under [What is live today](#what-is-live-today-the-domain-sends-and-receives-nothing).
4. **Beszel (Q42).** Record where its alerts go today in [beszel.md](../../services/beszel.md).
5. **Build:** [procedure](#procedure) steps 1–3, then step 4 for each wired app in order.
6. **Canary (Q50)** and the **probe assertions (Q23)**.
7. **Follow-ups:** the new-service checklist line (Q49) and the Mealie `email_verified` change
   (Q29), once Authentik sends mail.

### Provider choice (Q8)

Compared on 2026-09-21 against the answers above. Prices and limits are from the providers' own
pages that day.

| | Amazon SES (Frankfurt) | Scaleway TEM | Resend | Lettermint |
| - | ---------------------- | ------------ | ------ | ---------- |
| Company / data | US company, data in `eu-central-1` | French, EU only | US, EU region available | Dutch, data in NL |
| Cost at this volume | About $0.10 per 1,000 mails: cents a month | 300 a month free, then €0.25 per 1,000 | Free: 3,000 a month, **100 a day** | Free: **300 a month**, then €10 a month |
| Can an alert storm block resets (Q9)? | No, once out of the sandbox | No, pay per mail | Yes, the daily cap | Yes, the monthly cap |
| Credential pinned to one From address (Q11) | **Yes**: IAM condition `ses:FromAddress` per SMTP user | No; source-IP conditions only | Per domain, not per address | Not documented |
| DKIM (Q24) | **3 CNAMEs, rotated by AWS** | TXT, static | TXT, static | Not documented |
| Tracking (Q16) | Only if a configuration set asks for open/click events | None offered | Off by default | None on the free plan |
| Bodies stored (Q12) | **Never** | Not documented | 30 days, visible in the dashboard | 28-day retention |
| Bounces to Outlook (Q51) | SNS topic, email subscription | Webhook only | Webhook | Not documented |

Ruled out earlier: Postmark and Mailgun (a usable tier costs $15 a month or more; Postmark's free
tier is 100 mails a month, Mailgun's free logs last one day), SMTP2GO (paid from $10 a month, not
EU-hosted), Mailjet (its logo on free-plan mail, tracking on by default), Brevo (its terms could not
be checked; marketing-first).

**Why SES:** the only candidate that meets every hard answer, and it adds per-sender pinning.
**What it costs instead:** an AWS account to secure, a sandbox-exit request, and per-message logs
that have to be set up (step 1 below). **Fallback if SES refuses production access or goes away:**
Scaleway TEM, which is EU-native and simpler but has TXT DKIM and no per-sender pinning.

## Service assessment

Checked 2026-09-21 against the images pinned in `stacks/`, upstream docs and upstream source.
**Native** means the app has its own SMTP client. **Apprise** means it can post to an Apprise URL
(`mailtos://…`), which reaches email.

### Worth wiring

| Stack → component | Mail support | Would send | Notes |
| ----------------- | ------------ | ---------- | ----- |
| authentik | Native, env `AUTHENTIK_EMAIL__*` | Password-recovery links; address verification on enrollment and invitations; admin notifications through an email transport (failed system tasks, configuration warnings, new versions); optionally an emailed one-time code as an MFA stage | **Wire first.** Every public app logs in through Authentik, and today a user who forgets a password needs the admin. Verified addresses would also let the `mealie` provider assert `email_verified: true` honestly ([mealie.md](../../services/mealie.md), [Q29](#security)). |
| paperless | Native, env `PAPERLESS_EMAIL_*` | Password reset for its native users; the workflow **Email** action (for example "a document tagged *tax* arrived"); emailing a document from the UI | Paperless also *reads* mail (Mail accounts + Mail rules, IMAP) to consume attachments. That is receiving, not this runbook: see [Receiving mail](#receiving-mail) and [Q36](#receiving). |
| immich | Native, UI: Administration → Settings → Notification Settings → Email | Welcome mail on user creation, album invitations, album-update notices | Worth it once albums are shared with people outside the house. Users need an address in their profile; OIDC users get Authentik's. |
| jellyfin → seerr | Native, UI: Settings → Notifications → Email | Request approved, declined or available, to the requester; "new request pending", to the admin | Seerr users sign in with Jellyfin accounts, which carry no address. Each user's address has to be set in Seerr ([Q40](#per-service)). |
| books → shelfmark | Native, `EMAIL_SMTP_*` + output mode `email` | A fetched book to an e-reader's mail-in address (Send-to-Kindle and similar), with per-user recipient overrides | Only worth it if someone reads on such a device ([Q41](#per-service)). Those services accept approved senders only, so the From address must never change. Shelfmark caps attachments at 25 MB by default; the provider may cap lower ([Q10](#provider)). |
| beszel | Native, PocketBase admin `/_/` → Settings → Mail settings | Threshold alerts (CPU, memory, disk, temperature, system down); password reset for its local users | Where Beszel alerts go today is not recorded ([Q42](#per-service)). |
| a1-vps-kuma | Native, per notification (SMTP) | Monitor down/up, certificate expiry | The **out-of-house** watchdog. Email is a channel independent of Discord, which the NAS Kuma already uses ([Q43](#per-service)). |
| TrueNAS (host, not a stack) | Native: System → General Settings → Email, "Send Mail Method" SMTP / Gmail OAuth / Outlook OAuth | Pool, SMART and update alerts; the daily config email; UPS events once the [UPS](../../roadmap.md#6-ups) exists | **Already sending**, through Microsoft OAuth. Moving it is optional ([Q44](#per-service)). The trade-off is an OAuth grant that can lapse against a static credential, and the config DB (encrypted, seed excluded) passing through a third party. |

### Could use it, low value

| Stack → component | Mail support | Would send | Why low |
| ----------------- | ------------ | ---------- | ------- |
| mealie | Native, env `SMTP_*` | Invitation links, password reset | Password login is off (`ALLOW_PASSWORD_LOGIN=false`). Users arrive through Authentik, and an invite link can be pasted into a chat. |
| observability → grafana | Native, env `GF_SMTP_*` | Alert notifications, invites, password reset | No Grafana alert rules exist and there is one local admin. Worth more if alerting ever moves into Grafana ([Q45](#per-service)). |
| kuma (NAS) | Native, per notification | Monitor down/up | Already alerts to Discord; mail would be a second copy. |
| a1-vps-matrix → synapse | Native, `homeserver.yaml` `email:` section | Missed-message notifications; password reset for the break-glass local admin | Logins are Authentik SSO, so password reset covers one account. Missed-message mail is the only user-facing value ([Q46](#per-service)). |
| arr → sonarr, radarr, prowlarr | Native: Settings → Connect → Email (Prowlarr: Settings → Notifications) | Grab/import notices, health warnings (indexer down, disk full) | Mostly noise; the health warnings are the only part worth reading. |
| arr → bazarr, questarr | Apprise | Subtitle and release notices | Same. |
| downloads → qbittorrent | Native: Options → Downloads → Email notification | "Download finished" | Noise. It shares gluetun's network namespace, so the provider would see a VPN exit address logging in ([Q31](#security)). |
| downloads → sabnzbd | Native: Config → Notifications → Email | Job finished or failed, disk full | Same, including the VPN egress. |
| caddy → crowdsec | Native `email` notification plugin | One mail per alert or decision | Bans happen many times a day, so this would be a flood, not a signal. |
| komodo | **None native.** Alerters are Discord, Slack, Ntfy, Pushover and Custom. The Ntfy endpoint has an email field, which relays through the ntfy server's own SMTP. | Deploy failures, server unreachable | No alerter is configured at all today ([Q47](#per-service)). If one is added, Discord or ntfy fits better than mail. |
| Host cron scripts (dumps, restore drill, Kiwix, mirror trigger) | Can already mail through TrueNAS `mail.send`, as the config backup does | Failure reports | Failures already surface through Kuma push monitors, healthchecks.io and GitHub failure emails. |

### Receive-only (an address to publish, nothing to send)

| Where | Address used for | Notes |
| ----- | ---------------- | ----- |
| a1-vps-tor-bridge, a1-vps-webtunnel | `TOR_BRIDGE_CONTACT`, which becomes Tor's `ContactInfo` | Public on Relay Search, so it will attract spam. It should be an alias that can be dropped. |
| a1-vps-ntp | NTP Pool account; the pool mails operators about score problems | An account setting, not a stack setting. |
| DMARC reports | The `rua=` target | Only if reporting is wanted ([Q19](#dns-and-the-domain)). |
| `postmaster@`, `abuse@` (RFC 2142) | Conventional role addresses | Abuse desks and some receivers expect them on a sending domain ([Q33](#receiving)). |
| paperless | An IMAP inbox to consume attachments from | Needs a real mailbox, not a forwarder. Recent Paperless versions can instead read an existing Outlook or Gmail inbox over OAuth, with no domain involved. |
| Third-party accounts | GitHub, Cloudflare, Oracle Cloud, Hetzner, Tailscale, healthchecks.io, MaxMind, CrowdSec Console | Whether their login addresses move to the domain is [Q37](#receiving). |

### No mail at all

| Stack → component | Why |
| ----------------- | --- |
| files (FileBrowser Quantum) | No SMTP client; share links are handed out by hand. |
| games (GameVault), romm | No SMTP client upstream. |
| homarr | No SMTP client. |
| jellyfin → jellyfin | No native mail: password reset writes a PIN file on the server. Third-party newsletter plugins exist. |
| adguard, tailscale, snowflake, conduit, micro-vps-ingress | Nothing to tell a person by mail. Tailscale account notices come from Tailscale itself. |
| caddy → caddy | The ACME contact address is deliberately empty ([caddy.md](../../services/caddy.md)), and Let's Encrypt stopped sending expiry mail in 2025. |
| observability → vector, victoria-logs, victoria-metrics, geoipupdate | No alerting component; vmalert and Alertmanager are not deployed. |
| a1-vps-matrix → element-web, mautrix-whatsapp, postgres, caddy | Clients, bridges and plumbing. |
| arr → unpackerr, exportarr; downloads → gluetun, flaresolverr, exporters; jellyfin → jellyfin-exporter | Webhooks only (unpackerr) or metrics only. |
| github-runner | GitHub mails workflow failures itself. |
| `*-periphery` (4), `a1-vps-beszel-agent`, `micro-vps-beszel-agent` | Agents. Komodo Core or the Beszel hub does any notifying. |

### Future services (roadmap and service ideas)

| Candidate | Mail support | Value |
| --------- | ------------ | ----- |
| Vaultwarden ([roadmap #2](../../roadmap.md#2-vaultwarden--the-placement-is-the-decision)) | Native SMTP: invitations, address verification, new-device login notices, emergency access, email 2FA | **High**, and effectively required for invitations. If it lands on the A1, the provider keeps it independent of the NAS. Turn password hints off. |
| Karakeep or Linkwarden ([roadmap #3](../../roadmap.md#3-bookmarks--linkwarden-or-karakeep)) | Both have SMTP settings for sign-up verification or password reset; check the pick at build time | Low for one user. |
| Baikal / Radicale ([roadmap #4](../../roadmap.md#4-calendar-and-contacts-caldav)) | Baikal can send calendar invitations to attendees by mail (iMIP); Radicale cannot | Only if invitations to people outside go out from the self-hosted calendar. |
| Syncthing, UPS exporter, staging ([roadmap #1, #6, #7](../../roadmap.md#queue)) | None. UPS power events go through TrueNAS alerts. | None. |
| Off-NAS alert channel ([service-ideas #2](../../service-ideas.md#2-off-nas-alert-channel--a1)) | ntfy can forward notifications as mail through its own SMTP settings | Mail from the provider already *is* an off-NAS delivery path ([Q43](#per-service)). |
| changedetection.io | Apprise | **Medium**: alerts are the whole point of it. |
| Audiobookshelf | Native SMTP for "send ebook to device" | Same as Shelfmark. |
| Forgejo mirror | Native SMTP: notifications, password reset | Low for a mirror. |
| Speedtest Tracker, Home Assistant, Pinchflat, Lidarr | Native SMTP (Speedtest Tracker, Lidarr), a notify integration (Home Assistant), Apprise (Pinchflat) | Low. |
| Navidrome, Actual Budget, Miniflux, Memos, Jellystat, Stirling-PDF, game servers | None worth wiring | None. |

**Decided order** ([Decisions](#decisions-2026-09-21)): Authentik, Immich, A1 Kuma, Beszel, Seerr.
Add Vaultwarden when it lands.

## Open questions

**All answered on 2026-09-21**; each answer is in [Decisions](#decisions-2026-09-21). The questions
stay here for the reasoning behind each answer. Where there was an obvious default, it is under
**Suggested**.

### Addressing

- **Q1. Which sending subdomain?** `notify.`, `mail.` or something else. It shows in every From
  line. `nas.example.com` is already used in the docs, so not that one. A name that gets its own
  records stops the `*` wildcard from answering for it and everything below it, which is fine for a
  name that is not a web host. **Suggested:** `notify`.
- **Q2. Or send from the apex after all?** That only makes sense if a personal mailbox on the apex
  is planned *and* service mail should share its reputation. It also means replacing the apex SPF.
- **Q3. Which local parts?** Per service (`authentik@notify.example.com`, `immich@…`), per
  function (`alerts@`, `accounts@`), or one for everything (`nas@`, `noreply@`, `info@`)? Per
  service makes inbox filters trivial and shows which credential leaked. One address is simpler to
  put on an e-reader's approved-sender list. **Suggested:** per service.
- **Q4. Which display names?** "Authentik", "Immich (home)", your name, or a name for the whole
  setup? Friends see it, so pick one scheme for every app. A real name added to the docs also
  needs a `scrub` rule for the [public mirror](public-mirror.md).
- **Q5. `noreply`, or a real Reply-To?** A reply to a `notify` address bounces unless the subdomain
  gets an MX. Should a friend's reply to an Immich invitation reach you? Not every app can set
  Reply-To.
- **Q6. Which language?** German or English templates? Authentik's templates can be overridden;
  most apps' cannot.
- **Q7. Should people (you, household, friends) get addresses on the domain?** That is a mailbox
  project, not this one, but it decides Q2, Q18 and whether the apex null MX stays.

### Provider

- **Q8. Which provider?** Candidates: Brevo, SMTP2GO, Postmark, Mailgun, Amazon SES, Scaleway
  Transactional Email, Resend. Criteria: EU hosting, a free tier that covers the volume, subdomain
  sending, per-credential sender restriction (Q11), CNAME-delegated DKIM (Q24), attachment limit
  (Q10), log retention (Q12), tracking off by default (Q16).
- **Q9. What volume, and what happens at the cap?** Steady state is a handful of mails a day. An
  alert storm (Beszel or Kuma flapping) can burn a daily cap and block password resets for the rest
  of the day. One stream for everything, separate streams for alerts and account mail, or two
  providers?
- **Q10. Is the attachment limit big enough?** Shelfmark sends books (up to 25 MB by default). The
  TrueNAS config tarball has not been measured; measure it before moving TrueNAS.
- **Q11. Can a credential be tied to one From address?** If not, any leaked credential can send as
  every address on the subdomain. This could decide between providers.
- **Q12. What does the provider keep, and for how long?** Message bodies and logs would hold
  password-reset links and document mails. Is that acceptable, and what is the shortest retention
  setting?
- **Q13. Who owns the provider account, and how is it recovered?** 2FA on. Its recovery address
  must **not** be on this domain: losing the domain would lose the account that sends for it. Store
  the login in Bitwarden?
- **Q14. Free or paid, and what if it goes away?** Free tiers shrink and accounts get suspended.
  Is there a fallback: a second provider configured but idle, or TrueNAS left on OAuth?
- **Q15. SMTP or the provider's HTTP API?** **Suggested:** SMTP everywhere, because every app
  speaks it and switching provider is then a credential change.
- **Q16. Is tracking off?** Confirm that open and click tracking are off account-wide, not per
  message. Rewritten links break Authentik's one-time recovery links.
- **Q17. Is a shared IP enough?** At this volume, yes. Refuse any dedicated-IP upsell; a cold
  dedicated IP delivers worse than a warm shared pool.

### DNS and the domain

- **Q18. Keep the apex null MX and `*._domainkey` revocation for good?** Both have to go the day
  the apex sends or receives mail.
- **Q19. Collect DMARC aggregate reports?** They show who is spoofing the domain. A `rua=` target
  needs a receiving address, which clashes with the apex null MX unless it lives on a subdomain or
  another domain. Cloudflare's DMARC Management receives them for you and stays inside Cloudflare.
- **Q20. Own `_dmarc.notify`, or inherit the apex policy?** `p=none` with reports during rollout
  catches a misconfiguration without losing mail. Inheriting `sp=reject` is safe once DKIM
  verifies. **Suggested:** inherit, and test with the [procedure](#3-verify-before-any-app-uses-it)
  before wiring any app.
- **Q21. Enable DNSSEC?** The zone is unsigned. Signing protects the SPF, DKIM and DMARC records
  from forged DNS answers. The cost is one click in Cloudflare plus a `DS` record at the registrar,
  and the risk is that a wrong `DS` makes the whole domain unresolvable.
- **Q22. Who is the registrar, is auto-renew on, and where do renewal notices go?** A lapsed domain
  can be registered by someone else, who then receives every mail sent to it, including password
  resets for accounts registered with it. Renewal notices must go to an address **not** on the
  domain.
- **Q23. Should the mail records live in the repo or in a probe?** Cloudflare DNS is click-ops. The
  [edge access policy probe](edge-access-policy-probe.md) already asserts the Cloudflare proxy
  colour; it could also `dig` the four lockdown records and the sending records, and fail on
  drift.
- **Q24. Who rotates the DKIM key?** With CNAME delegation the provider rotates it; a pasted TXT
  key never changes. **Suggested:** prefer a provider that uses CNAMEs.
- **Q25. MTA-STS, TLS-RPT, BIMI?** The first two matter only for receiving. BIMI needs a paid
  certificate and gains nothing here. Skip all three unless Q7 or Q33 add an inbox.

### Security

- **Q26. Where does each credential live?** Env-configured apps: the vault env, then a Komodo
  Variable. UI-configured apps (Immich, Seerr, Beszel, Kuma, arr, TrueNAS): the app's database,
  and therefore ZFS snapshots, the Hetzner backup and the Postgres dumps. Keep a copy in Bitwarden
  for rebuilds, or rotate on rebuild?
- **Q27. Who may recover a password by mail?** Email recovery makes each user's mailbox a key to
  Authentik, and through it to every public app. Everyone, non-admins only, or nobody (admin
  resets)? **Suggested:** no email recovery for `akadmin` and the `authentik Admins` group.
- **Q28. Allow an emailed code as an MFA factor?** It is weaker than TOTP or a passkey, because
  whoever holds the mailbox holds the second factor.
- **Q29. Should Authentik mark addresses as verified?** If yes, the `mealie` provider could assert
  `email_verified: true` through a custom scope mapping, and Mealie's
  `OIDC_REQUIRES_EMAIL_VERIFICATION` could be turned back on.
- **Q30. Who notices a stolen credential?** Provider usage alerts or webhooks: to where? Is there a
  per-credential rate limit?
- **Q31. Do qBittorrent and SABnzbd send at all?** They exit through gluetun's VPN tunnel, and
  some providers block or flag logins from VPN or datacenter addresses. **Suggested:** leave them
  without mail.
- **Q32. What if egress gets locked down?** Nothing restricts container egress today (no
  `internal: true` network in `stacks/`). If that changes, SMTP to the provider must stay open;
  record it wherever the lockdown is written down.

### Receiving

- **Q33. Receive anything at all?** Candidates: `postmaster@` and `abuse@`, a security contact, Tor
  `ContactInfo`, the NTP Pool account, DMARC reports, the Paperless inbox, replies to service mail.
- **Q34. Forward or store?** Cloudflare Email Routing forwards for free, but it cannot serve a
  Paperless IMAP inbox. A hosted mailbox can.
- **Q35. On which name?** The apex (remove the null MX, change SPF) or a subdomain (the apex stays
  locked)?
- **Q36. The Paperless inbox: a mailbox on the domain, or Paperless reading the existing Outlook
  inbox over OAuth?** OAuth needs no domain and no new mailbox.
- **Q37. Move third-party account logins to domain aliases?** GitHub, Oracle Cloud, Hetzner,
  Tailscale, healthchecks.io, MaxMind, CrowdSec Console, NTP Pool: possible. **Never** the
  registrar, Cloudflare or the mail provider itself, because each of those is needed to repair the
  domain.

### Per service

- **Q38. Authentik: which flows send mail?** Recovery, enrollment verification, invitations? Custom
  templates and branding? Admin notifications by mail, or left in the UI?
- **Q39. Immich: album notifications on by default?** Users can opt out in their own settings.
- **Q40. Seerr: who gets request mail, and who enters users' addresses?** Jellyfin accounts carry
  none.
- **Q41. Shelfmark: does anyone use a mail-in e-reader?** If so, which sender address goes on its
  approved list? It must then never change (Q3).
- **Q42. Beszel: where do its alerts go today?** Should mail be the primary channel or a second
  one?
- **Q43. A1 Kuma: add mail next to Discord?** Mail from an external provider already reaches you
  while the NAS is dark. Does that settle the [off-NAS alert channel](../../service-ideas.md#2-off-nas-alert-channel--a1)
  idea, or is Matrix or ntfy still wanted for phone push?
- **Q44. TrueNAS: move from Microsoft OAuth to the provider?** Then the daily config email becomes a
  daily end-to-end proof that the provider path works. Keeping OAuth instead leaves an independent
  second path if the provider fails.
- **Q45. Grafana: will alert rules ever live there?** If not, skip its SMTP.
- **Q46. Synapse: are missed-message mails wanted?** Does Synapse even know users' addresses from
  the OIDC claims?
- **Q47. Komodo: add an alerter at all?** Not mail, but today deploy failures show up only as GitHub
  failure emails.
- **Q48. arr, downloads, CrowdSec: leave them without mail?** **Suggested:** yes; they are noise.
- **Q49. New services: add "SMTP credential" to the [new-service checklist](new-service.md)?**
  Vaultwarden is the first one that needs it.

### Operations

- **Q50. What proves mail still works?** healthchecks.io checks accept pings by email: a daily
  mail through the provider to a check's address proves delivery end to end, and the check goes
  red when it stops. A Kuma TCP monitor on the provider's port 587 proves only reachability.
- **Q51. Who sees bounces?** After a hard bounce the provider suppresses that recipient, and from
  then on, for example, their password resets silently do not go out. Where do bounce and complaint
  notices go?
- **Q52. Where is each app's mail config recorded?** **Suggested:** the env table in each
  `docs/services/<name>.md`, plus a *Wired* column added to the assessment above.
- **Q53. What catches a Renovate bump that breaks mail?** An upstream env-var rename would fail
  silently; the deploy health check does not send mail. Re-test with the app's own test button after
  a major bump?
- **Q54. What is the cost ceiling, and who pays?**
- **Q55. Public mirror.** The sending subdomain and its addresses are covered by the existing
  `example.com` scrub rule. A provider's own domain written into the docs (an SMTP host name, for
  example) needs an `allow-domain` line in the same commit
  ([public-mirror.md](public-mirror.md)).

## Procedure

Written for the chosen provider, Amazon SES. Everything happens in region **`eu-central-1`**; SES
state, including the sandbox, is per region. Placeholders: `<account-id>` is the AWS account,
`<stack>` the stack being wired, `<app>` its address local part (Q3).

### 1. Set up the SES account

1. **Account (Q13).** Create the AWS account with the Outlook address as root email. Put MFA on
   root and never create root access keys. Store the login and MFA recovery in Bitwarden. Use an
   MFA-protected admin identity for console work, not root.
2. **Sending identity.** SES → Identities → Create identity → Domain `notify.example.com`, Easy
   DKIM, RSA 2048. Leave custom MAIL FROM off: DKIM alone carries DMARC (see [Design](#design)).
3. **Sandbox exit.** Request production access: mail type *Transactional*, a short description
   (password resets, invitations and alerts for a household's self-hosted services, well under 100
   a day, bounces and complaints handled through SNS). AWS answers within about 24 h. Until then
   SES only delivers to verified addresses, so verify the Outlook address as an identity for the
   step 3 test.
4. **Bounces and complaints (Q51).** SNS topic `ses-feedback`, email subscription to the Outlook
   address (confirm the link it sends). On the identity, set it as the bounce and complaint
   notification topic, then turn **email feedback forwarding off**: it would send them to the
   `notify` address, which has no MX.
5. **Usage alerts (Q30).** An AWS Budget of $1 a month with an email alert, and a CloudWatch alarm on
   `AWS/SES` `Send` (sum over 1 hour above about 100) that notifies an SNS topic mailing the Outlook
   address. SES has no per-credential rate limit.
6. **Metadata for about 30 days (Q12).** A configuration set `default` with an EventBridge event
   destination for *send, delivery, bounce, complaint, reject* events, and an EventBridge rule that
   writes them to a CloudWatch Logs group with **30-day retention**. **Never select the open or
   click event types**: selecting them is what turns tracking on (Q16). Make it the identity's
   default configuration set.

### 2. Add the SES records in Cloudflare

SES shows three DKIM CNAMEs on the identity page. Add exactly those; nothing else is needed:

| Type | Name | Content | Proxy |
| ---- | ---- | ------- | ----- |
| CNAME | `<token1>._domainkey.notify` | The target SES shows for it | **DNS only** |
| CNAME | `<token2>._domainkey.notify` | The target SES shows for it | **DNS only** |
| CNAME | `<token3>._domainkey.notify` | The target SES shows for it | **DNS only** |

With custom MAIL FROM off there is no SPF, MX or bounce record under `notify`: the envelope sender
is an SES domain, whose SPF SES publishes itself.

- **Every CNAME must be grey-cloud (DNS only).** A proxied CNAME is answered with Cloudflare's A
  records, so the DKIM lookup finds no key.
- **Do not touch the four apex records.** The apex `*._domainkey` wildcard does not cover
  `<selector>._domainkey.notify`, which sits under a different parent, so the two do not clash.
- Add `_dmarc.notify` only if Q20 says so.

### 3. Verify before any app uses it

1. Wait for the identity to show *Verified* with DKIM *Successful*, and check the records from
   outside:

   ```sh
   dig +short CNAME <token1>._domainkey.notify.example.com @1.1.1.1
   dig +short TXT   <token1>._domainkey.notify.example.com @1.1.1.1   # resolves to p=…
   dig +short TXT   _dmarc.notify.example.com @1.1.1.1                # empty (Q20)
   ```

2. Create a throwaway credential and send one test message, without putting the password on the
   command line:

   ```sh
   read -rp 'SMTP user: ' U; read -rsp 'SMTP password: ' P; echo
   printf 'From: test@notify.example.com\r\nTo: <you>\r\nSubject: provider test\r\n\r\nhello\r\n' >/tmp/m.txt
   printf 'machine email-smtp.eu-central-1.amazonaws.com login %s password %s\n' "$U" "$P" >/tmp/netrc && chmod 600 /tmp/netrc
   curl --ssl-reqd --url 'smtp://email-smtp.eu-central-1.amazonaws.com:587' --netrc-file /tmp/netrc \
     --mail-from test@notify.example.com --mail-rcpt '<you>' --upload-file /tmp/m.txt
   rm -f /tmp/netrc /tmp/m.txt
   ```

3. In the received mail, open the original headers. `Authentication-Results` must show
   `dkim=pass header.d=notify.example.com` and `dmarc=pass`. `spf=pass` is for the SES envelope
   domain; SPF not aligning is expected.
4. Re-run the `dig` checks under [What is live today](#what-is-live-today-the-domain-sends-and-receives-nothing):
   the apex lockdown must be unchanged.
5. Delete the throwaway credential.

### 4. Wire one service

**Env-configured apps** (Authentik, Paperless, Mealie, Grafana, Shelfmark, Synapse):

1. Create the stack's SES credential (see [SES credential per stack](#ses-credential-per-stack)).
2. `scripts/secrets.sh edit <stack>` and add the variables (see the reference table below).
3. `scripts/secrets.sh push <stack>` **before** merging the compose change that references them. A
   compose change that lands first deploys with empty values
   ([secret-sync runbook](secret-sync.md)).
4. Reference them in `stacks/<stack>/docker-compose.yml` as `${VAR}`; never write the value itself.
5. Add the variables to the env table in `docs/services/<stack>.md` in the same PR.
6. After the deploy, send the app's own test mail and check the headers as in step 3.

**UI-configured apps** (Immich, Seerr, Beszel, both Kumas, arr, SABnzbd, qBittorrent, TrueNAS):
steps 1 and 6, with the settings entered in the UI. Note in `docs/services/<stack>.md` that the
app sends mail and which address it uses. The credential's copy goes in Bitwarden (Q26).

#### SES credential per stack

1. SES → SMTP settings → **Create SMTP credentials**, IAM user name `ses-<stack>`. Save the SMTP
   user name and password it shows once.
2. In IAM, replace that user's generated policy (it allows sending as anything, from any identity)
   with one pinned to the stack's address (Q11):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": "ses:SendRawEmail",
       "Resource": [
         "arn:aws:ses:eu-central-1:<account-id>:identity/notify.example.com",
         "arn:aws:ses:eu-central-1:<account-id>:configuration-set/default"
       ],
       "Condition": { "StringEquals": { "ses:FromAddress": "<app>@notify.example.com" } }
     }]
   }
   ```

   The configuration-set ARN is needed because the identity sends through `default` (step 1.6);
   without it, every send fails as not authorized.
3. SMTP settings for the app: host `email-smtp.eu-central-1.amazonaws.com`, port 587 with
   STARTTLS (or 465 with implicit TLS), From `<app>@notify.example.com`, display name as in Q4.
4. Prove the pinning: send once with a different From address. It must be refused.

| App | Where | Keys |
| --- | ----- | ---- |
| Authentik | env, both `server` and `worker` | `AUTHENTIK_EMAIL__HOST`, `__PORT`, `__USERNAME`, `__PASSWORD`, `__USE_TLS`, `__USE_SSL`, `__TIMEOUT`, `__FROM`. Test: `ak test_email <address>` in the worker container |
| Paperless | env | `PAPERLESS_EMAIL_HOST`, `_PORT`, `_HOST_USER`, `_HOST_PASSWORD`, `_FROM`, `_USE_TLS`, `_USE_SSL` |
| Mealie | env | `SMTP_HOST`, `SMTP_PORT`, `SMTP_AUTH_STRATEGY` (`TLS`/`SSL`/`NONE`), `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`, `SMTP_USER`, `SMTP_PASSWORD` |
| Grafana | env | `GF_SMTP_ENABLED`, `GF_SMTP_HOST` (`host:port`), `GF_SMTP_USER`, `GF_SMTP_PASSWORD`, `GF_SMTP_FROM_ADDRESS`, `GF_SMTP_FROM_NAME` |
| Shelfmark | env or settings UI | `EMAIL_SMTP_HOST`, `_PORT`, `_SECURITY`, `_USERNAME`, `_PASSWORD`, `EMAIL_FROM`, `EMAIL_RECIPIENT`; output mode `email` |
| Synapse | `homeserver.yaml` | `email:` section: `smtp_host`, `smtp_port`, `smtp_user`, `smtp_pass`, `notif_from`, `enable_notifs` |
| Immich | UI | Administration → Settings → Notification Settings → Email |
| Seerr | UI | Settings → Notifications → Email |
| Beszel | UI | PocketBase admin `/_/` → Settings → Mail settings; then per user, Settings → Notifications |
| Uptime Kuma | UI | Settings → Notifications → Setup Notification → Email (SMTP) |
| TrueNAS | UI | System → General Settings → Email → Send Mail Method: SMTP |

Check the exact variable names against upstream docs when wiring. Renovate may have moved the
version on since this table was written.

### 5. Remove a service, or all of it

- **One service:** delete the `ses-<stack>` IAM user, then remove the settings and variables.
  The other services are unaffected.
- **Everything:** delete every `ses-*` IAM user and the SES identity, then delete the `notify`
  records in Cloudflare. With no records of its own, `notify` falls back to the apex `sp=reject`,
  so spoofing it is rejected again. Leave the four apex records in place.

## Receiving mail

Not part of this plan (Q33–Q37). If it happens:

- **Any inbound address needs an MX.** On the apex, that means deleting the null MX and replacing
  `v=spf1 -all` with the mail host's SPF. A subdomain keeps the apex locked.
- **Forward only:** Cloudflare Email Routing adds its own MX and SPF records and forwards to an
  existing inbox. No storage, no IMAP.
- **A real mailbox:** a hosted mail provider with MX, SPF, DKIM, DMARC and autoconfig records. That
  is its own runbook.
