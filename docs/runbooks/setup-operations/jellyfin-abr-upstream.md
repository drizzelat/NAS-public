# Upstreaming the Jellyfin adaptive bitrate patches

What it would take to turn [`stacks/jellyfin/patches/`](../../../stacks/jellyfin/patches/) from a
working private fork into something the Jellyfin project would merge. What the patches *do* and how
to carry them to a new release is the [jellyfin-abr-image runbook](jellyfin-abr-image.md); what they
change in behaviour is [jellyfin.md → Transcoding and bitrate](../../services/jellyfin.md#transcoding-and-bitrate).

Nothing here is needed to keep the NAS running. This is the gap between *works for one household on
one server* and *runs on every Jellyfin install*, written down so the decision to attempt it (or not)
is an informed one.

## The two bars

The patches clear the first bar and not the second:

| Bar | Status |
| --- | --- |
| Works on this NAS, for these clients, at these bitrates | Met — see the runbook's scratch-instance test |
| Safe as a default for an admin who never reads a changelog | Not met — no config, no cap on the extra transcode, no tests, one uplink's worth of tuning |

Everything below is the second bar.

## Configuration: what is hard-coded, and where it would have to live

**Jellyfin has no environment-flag culture for playback.** The `JELLYFIN_*` variables cover paths and
the ffmpeg binary only. Server-side behaviour lives in strongly-typed config classes that are
serialised to XML, edited in the Dashboard and exposed over the API:

- `EncodingOptions` → `/config/encoding.xml`, Dashboard → Playback → Transcoding,
  `GET/POST /System/Configuration/encoding`. Its existing neighbours are the right precedent:
  `EnableThrottling`, `ThrottleDelaySeconds`, `EnableSegmentDeletion`, `SegmentKeepSeconds`.
- `ServerConfiguration` → `/config/system.xml`. Holds `RemoteClientBitrateLimit`.
- Client-side constants belong in jellyfin-web's `appSettings` (per-device, `localStorage`), not in
  the server config.

Adding a property to `EncodingOptions` is an **additive OpenAPI change**: it flows into the generated
spec (`openapi-generate.yml`) and every downstream SDK. Additive is allowed, but it is a versioned
API commitment, so each knob has to earn its place rather than be exposed "just in case".

### Server — `DynamicHlsHelper.cs`

| Hard-coded now | Value | What upstream would want |
| --- | --- | --- |
| `_adaptiveBitrateRungs` | `(0.5, 1280×720, 4 Mbps)`, `(0.25, 960×540, 2 Mbps)`, `(0.125, 640×360, 1 Mbps)` | The central design question — see below. At minimum an admin on/off switch; at most an admin-defined ladder |
| Rungs above the request | double the requested bitrate, up to `0.9 ×` the source within `RemoteClientBitrateLimit` | Same design question. The 0.9 is load-bearing: a variant at the source bitrate is stream-copied, and a copy's segments follow the source keyframes rather than the ladder's grid |
| Minimum useful rung | `250000` | Constant is defensible; needs a comment saying why 250 kbps and not 150 |
| "Worth an encoder restart" margin | `> previousVideoBitrate * 0.75` | Same — document the reasoning or make it a named constant |
| Audio downgrade rule | `videoBitrate < 1500000 && audioBitrate > 128000` → 128 kbps | Probably fine as a constant, but it silently overrides a user's audio bitrate choice |
| `-floor` suffix on `PlaySessionId` / `DeviceId` | string literal | Not a knob — a design flaw. See [Design questions](#design-questions-to-settle-first) |

An `EnableAdaptiveBitrateTranscoding` flag in `EncodingOptions`, defaulting to **off**, is the
smallest credible shape: the ladder costs an extra ffmpeg process per playing session, and an admin
who upgrades into that without asking for it has a right to be annoyed.

### Server — `DynamicHlsController.cs`

| Hard-coded now | Value | Note |
| --- | --- | --- |
| Init-segment wait in `GetInitSegmentResult` | 30 000 ms, polled every 100 ms | Holds a request thread. Upstream would ask for a completion signal from the transcode manager instead of a poll loop |
| Aligned-start detection | reads `Request.Query["EnableAdaptiveBitrateStreaming"]` | Style violation: the parameter is already bound on the DTO. Fix before submitting, not a config question |

### Web — `hlsFloorLevel.js`

| Constant | Value | Note |
| --- | --- | --- |
| `FLOOR_AHEAD` | 30 s | How far past the buffer the lowest rung is pre-fetched. Costs bandwidth and server CPU on every session |
| `RESCUE_BUFFER` | 4 s | Below this, a late fragment is abandoned |
| `RECOVER_BUFFER` | 10 s | Buffer the floor must rebuild before climbing again |
| `SWITCH_MARGIN` | 10 s | Buffer a manual pick leaves in place |
| `CHECK_INTERVAL` | 250 ms | A `setInterval` running for the whole session |
| `beforeInit` expiry | 30 000 ms | |
| Recovery threshold | two samples, both `> 2 × nextBitrate` | |
| `CLIMB_STEADY` | 30 s | How long the estimate must carry a level playback has not used before it opens up |
| `CLIMB_DWELL` | 60 s | Minimum between two steps up, so a flapping link does not restart the encoder |
| `CLIMB_HEADROOM` | 1.4 | Headroom over such a level's bitrate the estimate has to show |

These are tuned for one uplink (40 Mbit/s up, ~32 Mbps remote cap) and one client mix. On a 4G phone
or a 500 Mbit fibre link they are guesses. Upstream will want either a defence of each number or a
smaller mechanism with fewer of them.

### Web — `plugin.js`

`abrEwmaDefaultEstimate: maxStreamingBitrate * 1.05` seeds the estimate high enough for the level
built for the measured bitrate to be the one hls.js starts on, and low enough that the level above it
is not. **The margin is a magic number sitting between two server-side ones** — the ladder's step
between levels, and the `1.33` gap the top level needs to earn its place. If either moves, the seed
silently starts playback a level too high. They need to come from one place.

## Design questions to settle first

These belong in a `jellyfin-meta` discussion *before* any code, because the answers change what gets
written. The dev guidelines require it for anything spanning server and web.

1. **Does Jellyfin want per-variant transcodes at all?** Today one session is one ffmpeg. The patches
   make it two (playing rung + floor rung). A server with ten remote users goes from ten ffmpeg
   processes to twenty. Jellyfin has **no global cap on concurrent transcodes** — only per-user
   `MaxActiveSessions` in `UserPolicy`. Answering "yes" implies building that cap. This is the
   question the whole feature rests on; everything else is detail.
2. **Who decides the ladder?** Fixed rungs (as now), derived from the source resolution, or
   admin-defined? Fixed rungs are wrong for a 480p source and wasteful for a 4K one.
3. **How does a session own more than one transcode?** `AddFloorSuffix` appends `-floor` to
   `PlaySessionId` and `DeviceId` so `KillTranscodingJobs` does not stop the floor job and the fake
   device stays out of the session's transcoding info. It works, and it is a string hack that
   fabricates a device. The honest version is a first-class *variant of a session* concept in
   `ITranscodeManager` and the session bookkeeping. That is a much larger change than the ladder
   itself, and it is the piece most likely to be rejected on sight.
4. **How is a transcode's output path identified?** The patch appends `VideoBitRate` to the hash in
   `StreamingHelpers.GetOutputFilePath`, which changes the path for **every** stream on the server,
   ABR or not, and invalidates in-flight transcode reuse once on upgrade. An explicit variant key
   passed in would be narrower. Needs agreement either way.
5. **Who pays for gapless switching?** The aligned start strips `-noaccurate_seek`, re-encodes one
   extra segment per switch, and adds an `atrim` on the AAC 1024-sample grid. The alternative is
   forcing a shared keyframe grid across all rungs with `-force_key_frames`, which costs quality at
   a fixed bitrate instead of costing CPU. Upstream should pick one.
6. **How does this interact with throttling and segment deletion?** `EnableThrottling` pauses ffmpeg
   180 s ahead of playback and `SegmentKeepSeconds` deletes behind it. Both now apply to two jobs
   whose playheads differ. Untested territory.
7. **How much of `hlsFloorLevel` can hls.js do itself?** The file subclasses `Hls.DefaultConfig.loader`,
   fetches fragments outside hls.js, **forges `stats.loading.*` timings** to steer hls.js's own
   bandwidth estimate, and fires `Hls.Events.BUFFER_FLUSHING` from outside. That is deep coupling to
   internals of a dependency that moves (currently 1.6.16), and it is exactly the "fragile and
   over-engineered complexity" the project says it exists to remove. A smaller version built on
   `abrController`, `maxStarvationDelay` and `nextLoadLevel` should be attempted first, even if it
   performs worse — a mergeable 80 % beats an unmergeable 100 %.
8. **What about clients that are not jellyfin-web?** The server change is client-agnostic, but only
   the web client requests the ladder and only the web client shows the playing bitrate. Android,
   iOS and the TV apps get an unused ladder or nothing.
9. **Scope edges.** LAN clients never see the ladder; *Auto* on a fast link starts as a remux and has
   none; Live TV is untouched. Each is a deliberate limitation that needs stating rather than
   discovering.

## What blocks default-on

The two playback glitches this feature started with — a sub-0.2 s video skip at a rung change and
about 30 ms of silence at a fresh transcode — were both fixed by the segment-grid alignment
(`IsAlignedAdaptiveBitrateStart`), and verified gapless on the scratch instance. What remains:

- **Two ffmpeg processes per playing session**, with no admin control over that (question 1). This
  is the blocker.
- **The alignment holds only where it applies** — transcoded video, fMP4 segments, past the first
  segment. Outside those conditions the old behaviour is still there, untested.
- **No tests.** Nothing in the change is covered. The pure parts are testable today:
  server-side ladder selection (extract it out of `DynamicHlsHelper` into something
  `tests/Jellyfin.Api.Tests/Helpers` can reach) and, on the web side, `parsePlaylist`, `getBufferEnd`
  and the rung-selection in `setAdaptiveBitrateLimit`.
- **One uplink's worth of evidence.** Every threshold was tuned against a 40 Mbit/s upload with a
  32 Mbps remote cap, on Chrome with DevTools throttling. No mobile-network data, no TV browsers.

## Work that is mechanical, not a design question

- **Rebase onto `master`, not a release tag.** The patches are `git diff v10.11.11`; upstream `master`
  is version 13. The anchors all still exist (`GetBitrateVariation`, the `fmp4 init file` log line,
  the `GetCommandLineArguments` signature), so this is shifting context, not a rewrite.
- **`hlsFloorLevel.js` must become TypeScript.** jellyfin-web's contributing guide: *"New files MUST
  be written in TypeScript."* 585 lines, including the hls.js surfaces it touches.
- **Drop the `eslint-disable-next-line compat/compat`.** jellyfin-web already ships
  `abortcontroller-polyfill` in `src/lib/legacy/index.ts`, and there is no precedent anywhere in the
  tree for disabling that rule. Fix the eslint `settings.polyfills` instead.
- **Import `Hls` properly** rather than relying on the global, which is a legacy-JS habit.
- **Separate the unrelated behaviour change.** Removing the `IsCopyCodec(state.OutputAudioCodec)`
  guard from `EnableAdaptiveBitrateStreaming` is its own fix with its own rationale.
- **CI to pass:** server `ci-format` (StyleCop) and `ci-tests`; web `lint`, `build:check` (`tsc`),
  `build:es-check` (the bundle is scanned for **ES5** syntax), `stylelint`, `test`, SonarCloud.

## Process gates

- **Two repositories, two pull requests.** Server first; the web PR carries a `backend` label and
  waits. Reviewers run `master` server against `master` web, so both can be open at once.
- **Meta discussion before code**, per the [development guidelines](https://jellyfin.org/docs/general/contributing/development/),
  because the change spans sub-projects.
- **LLM disclosure is mandatory and specific.** Both PR templates have a *Code assistance* section:
  exact tool, model, version, and what it did — "Do NOT editorialize on code ownership, confidence,
  or any other aspect of LLM usage." The [LLM policy](https://jellyfin.org/docs/general/contributing/llm-policies/)
  then requires that review comments be answered in your own words, unaided. On this code that means
  defending, cold, why the AAC `atrim` lands on the 1024-sample grid and why `stats.loading.first` is
  forged. Non-compliance is a ban, not a rejection.
- **Web PR checklist** includes giving a *substantive* review of another open web PR.
- **Titles in the imperative mood, no conventional-commit prefix.** `feat(...)` is explicitly out.
- **No rebasing or force-pushing once review has started.**
- **Two administrative approvals to merge.**

## If it were split into pull requests

Server, in order, each standing alone:

1. Don't restart a running transcode when the fMP4 init segment is requested — a self-contained
   bugfix worth having on its own, and the cheapest way to establish credibility.
2. Extract `GetSegmentLengthMs`. Trivial refactor.
3. Allow adaptive bitrate when audio is copied.
4. The real resolution-stepped ladder, replacing the ±variation one, plus per-variant transcode
   paths. The core, and where questions 1, 2 and 4 must already be answered.
5. Segment-grid-aligned rung starts. Depends on 4, needs question 5 answered.
6. The floor rung as its own job. Blocked on question 3 — likely a redesign, possibly a drop.

Web:

1. Request the ladder on *Auto*, plus `testBandwidth: false`, the `abrEwmaDefaultEstimate` seed and
   per-level buffer length. Smallest surface, real improvement, ship first.
2. Show the bitrate playing next to *Auto* (`getBitrateName`). Tiny; the PR needs a screenshot.
3. In-place quality switch without a restart (`setAdaptiveBitrateLimit`).
4. `hlsFloorLevel` — largest, most contentious, gated on question 7.

## Honest expectation

Server 1–3 and web 1–2 are straightforwardly mergeable once rebased, tested and disclosed. Server 4–5
and web 3 are real review cycles but defensible. Server 6 and web 4 hold most of the code and are
where the "over-engineered" reflex fires hardest — those need the meta discussion to go well before a
line is written.

The NAS keeps its own image either way. Upstreaming the lower half would shrink the patch set that
has to be rebased on every Jellyfin release, which is the practical reason to bother.
