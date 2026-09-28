# The pinned linuxserver image with Jellyfin.Api.dll and the web client rebuilt from the same upstream
# commit plus patches/ (adaptive bitrate). Why, and how to rebase the patches: docs/services/jellyfin.md → Image.
FROM lscr.io/linuxserver/jellyfin:10.11.11ubu2404-ls38@sha256:c9bb091532bec4fa12b3ce3c08d163cab2b369f5f30f1f30ca49a46d97f5eec8 AS base

# Reads from the stock assemblies which commit and assembly version to rebuild, so a new base never pairs with old sources.
FROM mcr.microsoft.com/dotnet/sdk:9.0@sha256:01fabc4758d1d74e39eda700c8463dae6241a61481f973683692ddcb59a5eeb7 AS version
COPY --from=base /usr/lib/jellyfin/bin/Jellyfin.Api.dll /usr/lib/jellyfin/bin/MediaBrowser.Controller.dll /stock/
RUN set -eu; mkdir /version; cd /stock; \
    pwsh -NoProfile -Command '[Diagnostics.FileVersionInfo]::GetVersionInfo("/stock/MediaBrowser.Controller.dll").FileVersion' > /version/release; \
    pwsh -NoProfile -Command '[Diagnostics.FileVersionInfo]::GetVersionInfo("/stock/Jellyfin.Api.dll").ProductVersion.Split("+")[1]' > /version/commit; \
    pwsh -NoProfile -Command '[Reflection.AssemblyName]::GetAssemblyName("/stock/Jellyfin.Api.dll").Version.ToString()' > /version/assembly; \
    head /version/*

FROM mcr.microsoft.com/dotnet/sdk:9.0@sha256:01fabc4758d1d74e39eda700c8463dae6241a61481f973683692ddcb59a5eeb7 AS server
COPY --from=version /version /version
COPY patches/jellyfin.patch /patches/
RUN set -eu; release=$(cat /version/release) commit=$(cat /version/commit) assembly=$(cat /version/assembly); \
    git clone --quiet --depth 1 --branch "v$release" https://github.com/jellyfin/jellyfin.git /src; cd /src; \
    [ "$(git rev-parse HEAD)" = "$commit" ] || { echo "v$release is not the commit the base image was built from ($commit)"; exit 1; }; \
    git apply /patches/jellyfin.patch; \
    dotnet build Jellyfin.Api/Jellyfin.Api.csproj -c Release -p:Version="$assembly" -o /out; \
    built=$(pwsh -NoProfile -Command '[Reflection.AssemblyName]::GetAssemblyName("/out/Jellyfin.Api.dll").Version.ToString()'); \
    [ "$built" = "$assembly" ] || { echo "built Jellyfin.Api $built, the base image loads $assembly"; exit 1; }

FROM node:22-bookworm@sha256:363e1587494626837fa7f9a23bdb453d13b0ff3c67c705c2805cfc69c2d2fad7 AS web
COPY --from=version /version /version
COPY patches/jellyfin-web.patch /patches/
RUN set -eu; git clone --quiet --depth 1 --branch "v$(cat /version/release)" https://github.com/jellyfin/jellyfin-web.git /src; cd /src; \
    git apply /patches/jellyfin-web.patch; \
    npm ci --no-audit --no-fund; \
    npm run build:production

FROM base
COPY --from=server /out/Jellyfin.Api.dll /usr/lib/jellyfin/bin/Jellyfin.Api.dll
RUN rm -rf /usr/share/jellyfin/web
COPY --from=web /src/dist/ /usr/share/jellyfin/web/
