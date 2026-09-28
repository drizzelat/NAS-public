# Jellyfin adaptive bitrate image

How to switch the `jellyfin` stack to the patched image, roll it back, and carry the patches to a
new Jellyfin release. What the image is and why: [jellyfin.md → Image](../../services/jellyfin.md#image).
What it would take to stop carrying the patches at all:
[jellyfin-abr-upstream](jellyfin-abr-upstream.md).

The patches change two things in public-facing code: `Jellyfin.Api.dll` and the web client. A new
build reaches the server only through a compose change that someone merges by hand.

## Switching to the patched image

1. **Merge the pull request that changes `stacks/jellyfin/Dockerfile` or `patches/`.** Its
   `build-jellyfin-image` check already built the image. On `main` the workflow builds it again,
   pushes `ghcr.io/drizzelat/nas-jellyfin:<linuxserver tag>` and prints the pin in the run summary.
   The compose file is unchanged, so the `jellyfin` deploy that follows leaves the running
   container alone (Komodo runs a plain `docker compose up -d`).
2. **First push only: make the package public.** GitHub → your profile → Packages →
   `nas-jellyfin` → Package settings → Change visibility → Public. The NAS holds no registry
   credential. Check from any host: `curl -s -o /dev/null -w '%{http_code}\n'
   'https://ghcr.io/token?scope=repository:drizzelat/nas-jellyfin:pull'` returns `200`.
3. **Test the image on a scratch instance** ([below](#testing-on-a-scratch-instance)).
4. **Open a pull request that replaces the `jellyfin` service's `image:`** in
   `stacks/jellyfin/docker-compose.yml` with the printed pin. Merge it by hand at a quiet time: the
   deploy recreates `jellyfin`, and every stream playing stops for about 30 s.
5. **Check** that `https://jellyfin.example.com` loads, then start something from outside the
   LAN (a phone off Wi-Fi) with quality on *Auto*. The settings menu shows *Auto* with the bitrate
   playing, and Dashboard → Activity lists the session. `docker logs jellyfin` must not show
   `Could not load file or assembly`.

## Rolling back

Revert the compose pull request, or set `image:` back to the `lscr.io/linuxserver/jellyfin` pin it
replaced, and merge. The patched image is the same Jellyfin release with the same database, so
nothing else needs undoing. Rolling back across a Jellyfin release is a downgrade, which Jellyfin
does not support: go back to the patched build of the running release instead.

## A new Jellyfin release

1. **Renovate opens `jellyfin image build`**, one pull request for everything
   `stacks/jellyfin/Dockerfile` pins: the linuxserver base, the .NET SDK and the Node image. Its
   `build-jellyfin-image` check shows whether the patches still apply and build.
2. **The patches do not apply or build** → rebase them in the forks:

   ```sh
   cd jellyfin            # the drizzelat/jellyfin clone, branch abr-prototype
   git fetch --depth 1 https://github.com/jellyfin/jellyfin.git tag v<new>
   git rebase --onto v<new> v<old> abr-prototype
   git diff v<new> abr-prototype > <NAS repo>/stacks/jellyfin/patches/jellyfin.patch
   ```

   Do the same for `jellyfin-web` and `jellyfin-web.patch`. Keep the two description lines at the
   top of each patch file; `git apply` skips everything before the first `diff --git`. Push the
   rebased branches, then add the patch files to the Renovate pull request.
3. **Merge it.** `main` pushes `nas-jellyfin:<new linuxserver tag>`.
4. **Renovate opens the `nas-jellyfin` bump for `stacks/jellyfin/docker-compose.yml`.** The sweep
   never merges it (`MERGE_SKIP_IMAGES`). Test the new tag on a scratch instance first, then merge
   it by hand.

A linuxserver rebuild of the same Jellyfin release (a new `-lsNN` suffix only) needs no rebase: the
build checks that the upstream commit is still the one the patches are made against.

## Testing on a scratch instance

A copy of the server on its own LAN port, so production is never touched. Everything below runs on
the NAS as `truenas_admin` with `sudo -n`.

1. **Copy the config**, without the regenerable cache:
   `rsync -a --exclude cache/ /mnt/apps/mediaserver/config/jellyfin/ /mnt/apps/jellyfin-abr-test/config/`.
   Never mount the production config directory.
2. **In the copy only, before the first start**, set `LocalNetworkSubnets` in
   `config/network.xml` to `127.0.0.1/32`. The server offers the ladder only to remote clients, and
   this makes every LAN browser count as remote.
3. **Run it** from the image under test, media read-only, LAN-only port, no restart policy:

   ```sh
   docker run -d --name jellyfin-abr-test --restart no --security-opt no-new-privileges=true \
     --cpus 4 --memory 4g -e PUID=950 -e PGID=950 -e TZ=Europe/Vienna --device /dev/dri:/dev/dri \
     -v /mnt/apps/jellyfin-abr-test/config:/config -v /mnt/data/mediaserver/data/media:/data/media:ro \
     -p 192.168.178.111:8097:8096 ghcr.io/drizzelat/nas-jellyfin:<tag>
   ```

4. **In the copy only:** clear every scheduled task's triggers (Dashboard → Scheduled Tasks) and
   turn off real-time monitoring and chapter image extraction on the libraries, so the copy does
   not scan or write on its own.
5. **Put a gzip proxy in front**, so playlists travel as they do through the edge: the
   `nas-caddy` image with a Caddyfile holding the `hls_playlists` snippet and
   `reverse_proxy jellyfin-abr-test:8096`, on a Docker network shared with the scratch container
   and its own LAN-only port.
6. **Play something with quality on *Auto*** and throttle the connection in Chrome DevTools
   (Network → throttling, or a custom profile). Look for:
   - the rung changing in the settings menu next to *Auto*, and no spinner when the throttle drops
     to a few hundred kbps;
   - the rung climbing back after the throttle is lifted, within about two minutes and without a
     second `PlaybackInfo` or `master.m3u8` request — that is the ladder reaching above the bitrate
     the client measured at playback start;
   - two ffmpeg processes for the session at most: `docker exec jellyfin-abr-test sh -c
     'ps -eo comm= | grep -cx ffmpeg'`;
   - no `A task was canceled` and no `Could not load file or assembly` in `docker logs`.
7. **Remove it:** both containers, their network and `/mnt/apps/jellyfin-abr-test`. The copied
   config holds every API key and user of the real server.
