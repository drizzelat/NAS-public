# The pinned linuxserver image with Jellyfin.Api.dll and the web client rebuilt from the same upstream
# commit plus patches/ (adaptive bitrate). Why, and how to rebase the patches: docs/services/jellyfin.md → Image.
FROM lscr.io/linuxserver/jellyfin:12.4ubu2604-ls60@sha256:b10044530553b2506f06279bf0b5223f9534f434f87a277da4b8fa8ac386cb58 AS base

# Reads from the stock assemblies which release, commit and assembly version to rebuild, so a new base never pairs
# with old sources. The file version has three parts (12.4.0) while the tag can have two (v12.4).
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:bef136a371963aaa46ec97882845ef6f54dec15728bb4b128b1c2a400ffbc9b4 AS version
COPY --from=base /usr/lib/jellyfin/bin/Jellyfin.Api.dll /usr/lib/jellyfin/bin/MediaBrowser.Controller.dll /stock/
RUN set -eu; mkdir /version; cd /stock; \
    pwsh -NoProfile -Command '[Diagnostics.FileVersionInfo]::GetVersionInfo("/stock/MediaBrowser.Controller.dll").FileVersion' > /version/release; \
    pwsh -NoProfile -Command '[Diagnostics.FileVersionInfo]::GetVersionInfo("/stock/Jellyfin.Api.dll").ProductVersion.Split("+")[1]' > /version/commit; \
    pwsh -NoProfile -Command '[Reflection.AssemblyName]::GetAssemblyName("/stock/Jellyfin.Api.dll").Version.ToString()' > /version/assembly; \
    release=$(cat /version/release); tag="v$release"; \
    git ls-remote --exit-code --tags https://github.com/jellyfin/jellyfin.git "refs/tags/$tag" >/dev/null || tag="v${release%.0}"; \
    echo "$tag" > /version/tag; \
    head /version/*

FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:bef136a371963aaa46ec97882845ef6f54dec15728bb4b128b1c2a400ffbc9b4 AS server
COPY --from=version /version /version
COPY patches/jellyfin.patch /patches/
RUN set -eu; tag=$(cat /version/tag) commit=$(cat /version/commit) assembly=$(cat /version/assembly); \
    git clone --quiet --depth 1 --branch "$tag" https://github.com/jellyfin/jellyfin.git /src; cd /src; \
    [ "$(git rev-parse HEAD)" = "$commit" ] || { echo "$tag is not the commit the base image was built from ($commit)"; exit 1; }; \
    git apply /patches/jellyfin.patch; \
    dotnet build Jellyfin.Api/Jellyfin.Api.csproj -c Release -p:Version="$assembly" -o /out; \
    built=$(pwsh -NoProfile -Command '[Reflection.AssemblyName]::GetAssemblyName("/out/Jellyfin.Api.dll").Version.ToString()'); \
    [ "$built" = "$assembly" ] || { echo "built Jellyfin.Api $built, the base image loads $assembly"; exit 1; }

FROM node:24-bookworm@sha256:9d266751ca3d7fdbe651c878ffd5ad0a42fed49a18c283509267c97f025b7496 AS web
COPY --from=version /version /version
COPY patches/jellyfin-web.patch /patches/
RUN set -eu; git clone --quiet --depth 1 --branch "$(cat /version/tag)" https://github.com/jellyfin/jellyfin-web.git /src; cd /src; \
    git apply /patches/jellyfin-web.patch; \
    npm ci --no-audit --no-fund; \
    npm run build:production

FROM base
COPY --from=server /out/Jellyfin.Api.dll /usr/lib/jellyfin/bin/Jellyfin.Api.dll
RUN rm -rf /usr/share/jellyfin/web
COPY --from=web /src/dist/ /usr/share/jellyfin/web/
# OpenCL tone mapping for Dolby Vision profile 5 and HLG: docs/services/jellyfin.md → Transcoding and bitrate.
RUN set -eu; apt-get update; apt-get install -y --no-install-recommends intel-opencl-icd; rm -rf /var/lib/apt/lists/*
