# Service: Jellyfin (+ Seerr)

## Overview

Media playback and its request front-end — the **public-facing** half of the old `mediaserver`
stack. It is the highest-value service in the group and gets its own risk verdict and its own
rollback instead of sharing one with fourteen others.

### Containers

| Container | Role |
| --- | --- |
| jellyfin | Media player / streaming server |
| seerr | Media request UI |
| jellyfin-exporter | Prometheus metrics (sessions, transcodes, library counts, tasks, storage) on `:9594`, for the *Media stack* dashboard |

## Stack

- **Stack folder:** `stacks/jellyfin/`
- **Compose file:** `stacks/jellyfin/docker-compose.yml`
- **Deploy:** Komodo Stack `jellyfin` on Server `nas` ([komodo.md → How an owned stack deploys](komodo.md#how-an-owned-stack-deploys)). A push to its
  folder deploys it through Komodo.
- **Image recipe:** `stacks/jellyfin/Dockerfile` builds `ghcr.io/drizzelat/nas-jellyfin`, the stock
  image with adaptive bitrate patched in. Compose does not use it yet — see [Image](#image).

## Access

| Service | URL | Port |
| --- | --- | --- |
| Jellyfin | `https://jellyfin.example.com` | 8096 |
| Seerr | `https://seerr.example.com` | 5055 |

**Jellyfin is public** behind Authentik SSO. **Seerr stays LAN-only** (not in the VPS SNI
allowlist; Caddy's `lan_only` snippet aborts any other client). The exporter has no route:
`victoriametrics` joins `proxy_jellyfin` and scrapes `jellyfin-exporter:9594` (job `jellyfin`).

## Volumes / data

| Container path | Host path | Purpose |
| --- | --- | --- |
| `/config` (jellyfin) | `/mnt/apps/mediaserver/config/jellyfin` | Jellyfin config |
| `/app/config` (seerr) | `/mnt/apps/mediaserver/config/seerr` | Seerr config |
| `/data/media` | `/mnt/data/mediaserver/data/media` | Media library |

> Host paths deliberately stayed under `/mnt/apps/mediaserver/` — the split regrouped *stacks*,
> not data. The Jellyfin cloud-sync task still excludes its regenerable `cache/` directory.

## Environment variables

Set from the vault (`secrets.enc/stack-env/jellyfin.env.age`) as the Komodo Variables `JELLYFIN__<KEY>` (`scripts/secrets.sh push jellyfin` writes them and deploys) —
see the [secret-sync runbook](../runbooks/setup-operations/secret-sync.md).

| Variable | Description |
| --- | --- |
| `JELLYFIN_EXPORTER_TOKEN` | A Jellyfin API key named `jellyfin-exporter` (Dashboard → API Keys). Server API keys act as admin, so it gets its own revocable key rather than reusing Seerr's |

## Dependencies

- **`media_net`** (external) — Seerr addresses `sonarr:8989` and `radarr:7878`, which live in the
  [`arr`](arr.md) stack. Those hostnames are stored in Seerr's own `settings.json`, not in
  compose, so this dependency is invisible to the repo.
- Intra-stack: Seerr → `jellyfin` on the plain `default` network.
- `proxy_jellyfin` (external) — defined by the `caddy` stack. `jellyfin-exporter` joins it so
  [observability](observability.md) can scrape it.
- `/dev/dri` passthrough (Intel iGPU) for hardware transcoding, group IDs 44 (video) and 107
  (render).

## Notes

- **Jellyfin is public behind Authentik SSO** (web UI only, via `9p4/jellyfin-plugin-sso`). The
  login page shows only *Sign in with authentik* plus Quick Connect; the native form is hidden
  (cosmetic only). The real block is Caddy's **public `:8443` site block**, which returns `403` for
  the password endpoints (`/Users/AuthenticateByName`, `/Users/{id}/Authenticate`, `/Users/Public`)
  — LAN/tailnet `:443` and Seerr's internal path keep native login.
- **Who may log in through SSO is the Authentik `nas-users` binding** (since 2026-09-16) — see
  [authentik.md → Application access](authentik.md#application-access-the-login-allowlist). It gates
  the SSO path only; Seerr and LAN native login run on Jellyfin's own accounts.
- **Seerr signs in with a Jellyfin username + local password**, so every household Jellyfin
  account must keep a strong local password even though SSO provisions it.
- Off-LAN native apps log in via **Quick Connect**, approved from an SSO'd web session.
- Jellyfin is **grey-cloud (DNS-only)** at Cloudflare.
- Full design: [jellyfin-authentik-sso runbook](../runbooks/setup-operations/jellyfin-authentik-sso.md).
- **The exporter is `rebelcore/jellyfin-exporter`** with the `transcoding`, `tasks` and `storage`
  collectors on top of the defaults. `activity` stays off: it needs the Playback Reporting plugin.
  The scrape job drops the `ip_address`, `client_version` and `last_access` labels, so client IPs
  never reach the 1-year metrics store (the same rule the Caddy counters follow) and a login does
  not mint a new series. Now-playing series are labelled by title, so every played item adds a few
  short-lived series; that is the intended cost of the *Now playing* table.

## Transcoding and bitrate

These are server settings, not repo state: they live in `/config/encoding.xml` and
`/config/system.xml` and are changed in Dashboard → Playback, or through
`/System/Configuration[/encoding]` with a server API key.

- **Intel QSV on the N100 iGPU.** Hardware decode is on for H.264, HEVC, MPEG-2, VC-1, VP8, VP9 and
  AV1, including 10-bit HEVC and VP9. Output is always H.264, because HEVC and AV1 *encoding* are off.
- **HDR tone mapping uses Intel VPP** (`EnableVppTonemapping`, ffmpeg `tonemap_vaapi`). It covers
  HDR10, HDR10+ and Dolby Vision with an HDR10 base layer, which is every HDR file in the library
  as of 2026-09-21. HLG and Dolby Vision profile 5 are *not* tone-mapped.
- **OpenCL tone mapping (`EnableTonemapping`) must stay off.** The linuxserver image ships no
  OpenCL runtime (`ffmpeg -init_hw_device opencl@va` fails with `-1001`), so enabling it would
  break HDR transcodes.
- **Remote bitrate cap is 32 Mbps** (`RemoteClientBitrateLimit`, about 80 % of the 40 Mbit/s home
  upload). The cap is per stream, so two remote streams can still fill the uplink. It applies only
  to clients Jellyfin classes as remote. Public-edge clients are classed as remote because their
  real IP reaches Jellyfin through PROXY protocol, then Caddy's `X-Forwarded-For` and
  `KnownProxies`. To check a path, call `/System/Endpoint` through it and look for
  `"IsInNetwork":false` (it needs a token: in the web client's console,
  `ApiClient.getEndpointInfo().then(console.log)`).
- **LAN is `192.168.178.0/24` minus `.201`–`.255`** (`LocalNetworkSubnets`, set 2026-09-25). The
  FRITZ!Box gives its VPN clients addresses from `.201` up, inside the home subnet. With the list
  empty, Jellyfin counted every private range as LAN, so VPN clients skipped the bitrate test, got
  140 Mbps and a remux, and never got the ladder. The exclusions are `!`-prefixed entries in the
  same list. Docker-network sources (172.16/12, which includes tailnet clients arriving as the
  gateway) are now remote too.
- **Transcode throttling and segment deletion are on**, with the defaults: ffmpeg pauses 180 s
  ahead of playback, and segments older than 720 s are deleted.
- **The stock image has no adaptive bitrate.** In the web client, *Auto* quality is one bitrate
  test at playback start. The client downloads 0.5, 1, then 3 MB from `/Playback/BitrateTest`, uses
  70 % of the measured speed, and caches the result for 1 h. LAN clients skip the test and get
  140 Mbps. Each session is one fixed-bitrate transcode, so changing quality restarts it and the
  player rebuffers. The server's `enableAdaptiveBitrateStreaming` ladder is never requested by
  jellyfin-web, and it would not help: all its variants share one transcode.
- **The patched image ([Image](#image)) has real adaptive bitrate** for remote web clients on
  *Auto*:
  - The server offers the requested bitrate plus up to three lower rungs: 50 % in a 720p box,
    25 % in 540p and 12.5 % in 360p, each a transcode of its own. hls.js switches between them
    without a rebuffer, but a switch shows only once the buffer ahead has played out, up to 30 s.
  - **The ladder also reaches above the requested bitrate**, doubling it up to a ceiling of 90 % of
    the source video bitrate, within the remote cap of 32 Mbps. The bitrate test only measures the
    moment playback starts, so without those rungs a stream begun on a bad link stayed at that link's
    quality for its whole run. The 90 % keeps the top rung a transcode: a variant asking for the
    source bitrate is stream-copied instead, and a copy cuts its segments on the source's own
    keyframes rather than on the ladder's grid, so a switch to it would not be gapless.
  - **Climbing is damped, falling is not.** Playback starts on the rung the bitrate test bought. A
    rung above it opens up once the bandwidth estimate has stayed 1.4× above it for 30 s, and at
    most once a minute, so a link that comes and goes does not restart the encoder each time; when
    it does open, everything the connection carries opens at once. Rungs that have played stay open,
    so recovery after an outage is immediate, and a manual pick above the ceiling raises it. hls.js
    also caps *Auto* at the player's own size, so a small window does not climb to a 1080p rung.
  - The lowest rung is kept loaded 30 s past the end of the buffer, and every rung's playlist is
    fetched in advance. While 15 s or more are buffered, the lowest rung keeps loading up to 5 min
    past the buffer, in browser memory (about 14–40 MB at a 0.375–1 Mbps floor), so an outage of a
    few minutes plays through on it. Below 15 s that extra loading stops and yields the connection
    to the rung playing; a seek discards it. The server throttle measures against the last segment
    downloaded, not playback, so the floor transcode keeps ahead. When a fragment will not arrive
    before the buffer drops below 4 s, playback drops to the lowest rung at once. A playing session therefore runs two ffmpeg processes — one,
    on a link so slow that the ladder has no rung below the requested bitrate.
  - The settings menu shows the bitrate playing now next to *Auto*.
  - A manual quality pick at or below the ladder's top rung caps the level in place, with no new
    transcode and no rebuffer; going back to *Auto* is the same. A pick above the top rung still
    restarts the stream.
  - **A remote stream on *Auto* always starts as a transcode.** The web client asks PlaybackInfo
    for no direct play, no remux and no video copy whenever it plays through hls.js. Before, *Auto*
    on a fast link started as a remux or direct play, which has no ladder, so a stream begun on a
    good link stayed at the source bitrate after the link got worse. The cost: remote *Auto* never
    gets the bit-exact source, and HDR is tone-mapped to SDR. A manual quality pick still allows
    both. iOS and Safari play HLS natively without the ladder and are left alone.
  - LAN clients never get the ladder, and *Auto* on LAN still direct-plays or remuxes.
  - Rung switches are gapless. Each rung's transcode starts one segment early with an exact seek
    onto the segment grid, and its AAC audio is trimmed onto the 1024-sample frame grid, so every
    rung cuts its segments at the same instants. This replaced two earlier glitches — a skip of up
    to 0.2 s at a rung change and about 30 ms of silence at a fresh transcode — and holds only
    where it applies: transcoded video, fMP4 segments, past the first segment.
- **The web player's buffer shrinks to 6 s at high bitrates.** jellyfin-web lowers the hls.js
  forward buffer from 30 s to 6 s in Chrome, Edge and Firefox when the client's max bitrate is at
  least 25 Mbps. On unstable links, such as a phone on a train, set that device's internet quality
  manually below 25 Mbps (Settings → Playback). The patched web client applies the rule to the rung
  loading, so the lower rungs keep 30 s.
- **Caddy gzips the HLS playlists** (`hls_playlists` snippet on both Jellyfin vhosts). jellyfin-web's
  long query strings make each variant playlist about 1.4 MB as sent; gzipped it is about 11 KB.
  Uncompressed, every rung switch waited for one on a slow link.

## Image

**Deployed since 2026-09-22:** `stacks/jellyfin/docker-compose.yml` pins `ghcr.io/drizzelat/nas-jellyfin`.
Rolling back and rebasing the patches are in the
[jellyfin-abr-image runbook](../runbooks/setup-operations/jellyfin-abr-image.md).

[`stacks/jellyfin/Dockerfile`](../../stacks/jellyfin/Dockerfile) takes the pinned
`lscr.io/linuxserver/jellyfin` image and replaces two things. Both are rebuilt from the upstream
commit the stock files were built from:

| Replaced | Built from |
| --- | --- |
| `/usr/lib/jellyfin/bin/Jellyfin.Api.dll` | `jellyfin` + [`patches/jellyfin.patch`](../../stacks/jellyfin/patches/jellyfin.patch) |
| `/usr/share/jellyfin/web/` | `jellyfin-web` + [`patches/jellyfin-web.patch`](../../stacks/jellyfin/patches/jellyfin-web.patch) |

- **The base image decides what gets built.** The Dockerfile reads the release, the commit and the
  assembly version out of the stock assemblies. The build fails if the release tag is not that
  commit, or if the new DLL's assembly version differs. A mismatched DLL stops the server with
  `Could not load file or assembly 'Jellyfin.Api, Version=…'`. Official builds stamp it with a
  version of their own, not the release (`24.4.0.0` for 10.11.11).
- **[`build-jellyfin-image.yml`](../../.github/workflows/build-jellyfin-image.yml) builds it** on a
  GitHub-hosted runner and checks that both patched parts are in the image. A pull request only
  builds. `main` pushes `ghcr.io/drizzelat/nas-jellyfin:<linuxserver tag>` and prints the pin.
- **The compose pin moves by hand**, like `nas-caddy`: the sweep never merges a `nas-jellyfin` bump
  (`MERGE_SKIP_IMAGES`). A Dockerfile bump only rebuilds the image.
- **The package is public**, so the NAS pulls it without a registry credential. The image carries
  modified GPL code; its source is upstream plus the two patch files, which the public mirror
  publishes.
- **The patches come from two private forks**, `drizzelat/jellyfin` and `drizzelat/jellyfin-web`,
  branch `abr-prototype`, one commit per change. Each patch file is `git diff v<release>` of that
  branch.
- **They are not upstreamable as they stand** — no admin config, no cap on the extra transcode, no
  tests. What closing that gap would take, and the design questions it raises, are in the
  [jellyfin-abr-upstream runbook](../runbooks/setup-operations/jellyfin-abr-upstream.md).

## Operations

### Restart / redeploy

Komodo → Stacks → `jellyfin` → **Restart** or **Deploy**, or push to `stacks/jellyfin/` (the runner deploys it
through Komodo).

### Upgrade

Pinned `tag@sha256:digest`; Renovate proposes bumps. **Read Jellyfin's release notes** — this is
the service whose major bumps most deserve a deliberate look, which is exactly what it could not
get while bundled with fourteen others.

Once compose runs the patched image, a new Jellyfin release needs the patches rebased and tested
before its `nas-jellyfin` bump is merged — see the
[jellyfin-abr-image runbook](../runbooks/setup-operations/jellyfin-abr-image.md#a-new-jellyfin-release).

### Restore from backup

1. Stop the stack.
2. Restore `apps/mediaserver/config/jellyfin` and `.../seerr` from a ZFS snapshot or Hetzner.
3. `data/mediaserver` (the media library) is **intentionally not backed up** — large and
   re-acquirable.
4. Start the stack.

### Common failures

- **No hardware transcode** → `/dev/dri` passthrough and iGPU group IDs 44 / 107.
  The *Active transcodes* table on the Media stack dashboard shows an empty *HW accel* column for
  software encodes.
- **HDR film looks washed out or grey when transcoded** → the tone mapping is not running. Check
  that `EnableVppTonemapping` is on and that the transcode log (`/config/log/FFmpeg.Transcode-*.log`)
  contains `tonemap_vaapi`. HLG and Dolby Vision profile 5 are outside VPP's coverage (see
  [Transcoding and bitrate](#transcoding-and-bitrate)).
- **Remote playback buffers although quality is set to *Auto*** → Auto is measured only once,
  when playback starts. Set a fixed quality below 25 Mbps on that device (see
  [Transcoding and bitrate](#transcoding-and-bitrate)).
- **`jellyfin` target down, exporter logs `401`** → the `jellyfin-exporter` API key was revoked.
  Create a new one, `scripts/secrets.sh edit jellyfin`, `push jellyfin`.
- **Seerr shows no Sonarr/Radarr** → they live in the `arr` stack; check `media_net`.
- **Public login fails but LAN works** → intended: the public edge `403`s the password endpoints.
  Use SSO or Quick Connect.
- **Authentik shows "Redirect URI Error" on the SSO button** → Jellyfin sent `http://` instead of
  `https://` and the provider matches `strict`. The plugin builds the redirect from
  `Request.Scheme`, which is only `https` when Jellyfin trusts the fronting proxy. Check
  Dashboard → Networking → **Known Proxies** (`network.xml` → `KnownProxies`) against the live
  `proxy_jellyfin` subnet — it must be Caddy's, not a stale one. Confirm the sent value in
  `docker logs authentik-server-1 | grep redirect_uri_no_match`.
- **SSO login works but the admin dashboard is missing** → the SSO plugin owns `IsAdministrator`
  whenever **Enable Authorization by Plugin** is on, and it *rewrites* the flag on every login.
  Empty `AdminRoles` (or a null `RoleClaim`) therefore demotes you each time, silently undoing any
  manual promotion. As-built: `RoleClaim = groups`, `AdminRoles = ["authentik Admins"]`.
