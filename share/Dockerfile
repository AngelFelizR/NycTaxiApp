# syntax=docker/dockerfile:1
###############################################################################
# Public share service image (master doc 1.1, 5.10, 8.6).
#
# Multi-stage: a Nix stage assembles the runtime closure, a second stage
# extracts exactly that closure. Nothing else is copied -- no models, no
# dataset, no Postgres credentials and no test tooling (5.10 says this service
# must never see POSTGRES_*).
#
#   docker build -f share/Dockerfile -t ghcr.io/angelfelizr/nyc-taxi-share:latest .
#
# Architectures: build on linux/arm64 (the VM's) -- `nixos/nix:2.35.2` is
# multi-arch, and building the Nix stage under emulation is what makes CI
# builds slow. See .github/workflows/ci.yml.
###############################################################################

ARG NIX_IMAGE=nixos/nix:2.35.2

# ─────────────────────────────────────────────────────────── stage 1: closure
FROM ${NIX_IMAGE} AS build

# Without the rstats-on-nix cache every build compiles the R packages from
# source. Same keys as Dockerfile layer 9a for the dev image.
RUN printf '%s\n' \
      "substituters = https://cache.nixos.org https://rstats-on-nix.cachix.org" \
      "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0=" \
      >> /etc/nix/nix.conf

WORKDIR /build
# The pins and the modules they feed: this layer only invalidates when a pin
# or a package set changes, which is most of what a rebuild would otherwise cost.
COPY nix/ ./nix/

RUN nix-build nix/system-runtime.nix -o /out-system && \
    nix-build nix/r-share.nix      -o /out-rshare  && \
    nix-build nix/r-shared.nix     -o /out-rshared && \
    nix-store -qR /out-system /out-rshare /out-rshared | sort -u > /closure

# The closure as a tarball rooted at /, so stage 2 gets exactly those store
# paths and not the builder's own toolchain.
RUN tar -C / -czf /closure.tar.gz -T /closure

# ────────────────────────────────────────────────────────── stage 2: runtime
FROM ${NIX_IMAGE} AS runtime

COPY --from=build /closure.tar.gz /tmp/closure.tar.gz
RUN tar -C / -xzf /tmp/closure.tar.gz && rm /tmp/closure.tar.gz

# Stable paths into content-addressed store locations. The symlinks are copied
# as symlinks and resolve once the closure above is in place.
COPY --from=build /out-system /opt/system
COPY --from=build /out-rshare  /opt/rshare
COPY --from=build /out-rshared /opt/rshared

# system-runtime.nix already carries R, fontconfig, the locales and the fonts.
ENV PATH="/opt/system/bin:${PATH}" \
    LOCALE_ARCHIVE="/opt/system/lib/locale/locale-archive" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    FONTCONFIG_FILE="/opt/system/etc/fonts/fonts.conf" \
    FONTCONFIG_PATH="/opt/system/etc/fonts" \
    XDG_DATA_DIRS="/opt/system/share:/opt/system/lib/X11/xkb" \
    # Merged library tree: the R package sets plus the yaml reader for
    # shared/*.yaml (docs/decisions/0003).
    R_LIBS_SITE="/opt/rshare/library:/opt/rshared/library"

# The image ships only its own code: share/ and the shared configuration it
# reads. Layout matters -- share/plumber.R resolves `root` as the parent of
# share/ and looks for ../shared from there, exactly as in the repository.
WORKDIR /app
COPY share/ /app/share/
COPY shared/ /app/shared/


# Phase 7 hardening: run unprivileged (ADR-004). The base image has no
# useradd and /etc/passwd is a symlink into the Nix store, so a numeric id
# with an explicit HOME is the portable choice. Everything R writes goes to
# /tmp, which docker-compose.prod.yml declares as a tmpfs; HOME points there
# so fontconfig, bslib and Shiny's session files have somewhere to land.
# curl is used by the healthcheck and comes from nix/system-runtime.nix (/opt/system),
# not from /root/.nix-profile, which a non-root user cannot traverse.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache
USER 65534:65534

EXPOSE 8001
# SHARE_* comes from the environment (docker-compose.prod.yml); there is no
# .env in the image on purpose -- it holds secrets.
CMD ["Rscript", "/app/share/plumber.R"]
