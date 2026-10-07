# syntax=docker/dockerfile:1
###############################################################################
# Private API image (master doc 1.1, 4.5, 5, 8.6).
#
# Multi-stage, same shape as share/Dockerfile. The API is the only service
# that gets the models and the dataset, and it gets them as read-only mounts
# at runtime (4.5: they are 345 MB and never go in an image).
#
#   docker build -f api/Dockerfile -t ghcr.io/angelfelizr/nyc-taxi-api:latest .
#
# The pin matters: nix/pkgs-api.nix is nixpkgs 2025-12-02 with R 4.5.2, the
# environment the models were trained in. Building the API against the UI's
# pin (4.6.1) would change nothing here but is not what was validated, so
# both system-runtime.nix and r-api.nix are instantiated against pkgs-api.nix.
#
# nix/r-api.nix deliberately carries no testthat: this file is the image's
# layer and no deployment runs a test.
###############################################################################

ARG NIX_IMAGE=nixos/nix:2.35.2

# ─────────────────────────────────────────────────────────── stage 1: closure
FROM ${NIX_IMAGE} AS build

RUN printf '%s\n' \
      "substituters = https://cache.nixos.org https://rstats-on-nix.cachix.org" \
      "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0=" \
      >> /etc/nix/nix.conf

WORKDIR /build
COPY nix/ ./nix/

# system-runtime.nix, not system.nix: the image never runs nix and the CLI
# was 206 MB of it (ADR-0008).
RUN nix-build -E '(let pkgs = import ./nix/pkgs-api.nix; in import ./nix/system-runtime.nix { inherit pkgs; })' -o /out-system && \
    nix-build nix/r-api.nix -o /out-rapi && \
    nix-store -qR /out-system /out-rapi | sort -u > /closure

RUN tar -C / -czf /closure.tar.gz -T /closure

# ────────────────────────────────────────────────────────── stage 2: runtime
FROM ${NIX_IMAGE} AS runtime

COPY --from=build /closure.tar.gz /tmp/closure.tar.gz
RUN tar -C / -xzf /tmp/closure.tar.gz && rm /tmp/closure.tar.gz

COPY --from=build /out-system /opt/system
COPY --from=build /out-rapi    /opt/r

ENV PATH="/opt/system/bin:${PATH}" \
    LOCALE_ARCHIVE="/opt/system/lib/locale/locale-archive" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    FONTCONFIG_FILE="/opt/system/etc/fonts/fonts.conf" \
    FONTCONFIG_PATH="/opt/system/etc/fonts" \
    XDG_DATA_DIRS="/opt/system/share:/opt/system/lib/X11/xkb" \
    # /opt/r-lib holds taxiapi, installed below from the source in the image
    # (ADR-0007); /opt/r/library is the Nix package set.
    R_LIBS_SITE="/opt/r-lib:/opt/r/library" \
    # 4.1: read when R starts, not when the code runs -- a fork after libgomp
    # built its pool deadlocks the trajectory child in futex_wait.
    OMP_NUM_THREADS="1" \
    OPENBLAS_NUM_THREADS="1" \
    VECLIB_MAXIMUM_THREADS="1"

# api/plumber.R resolves `root` as the parent of api/ and loads .env from
# there; the layout mirrors the repository (migrations are read from
# file.path(root, "api", "migrations")), and .env is absent on purpose --
# secrets arrive from the compose env_file instead, and load_dotenv skips
# what is already set.
WORKDIR /app
COPY api/ /app/api/

# ADR-0007: the API runs an installed package, not a pile of source() calls.
# Installed from the source that was just copied, so what runs is what the
# image contains and there is no store path that can go stale. pkgload is NOT
# here: plumber.R takes the library() branch precisely because the package is
# installed, and the dev-only tooling never reaches this layer. Run before
# USER below -- /opt/r-lib has to be writable, and R's default library would
# land in a HOME that points at a tmpfs.
RUN mkdir -p /opt/r-lib \
 && R CMD INSTALL --library=/opt/r-lib /app/api \
 && rm -rf /tmp/* /tmp/..?* /tmp/.[!.]*


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

EXPOSE 8000
CMD ["Rscript", "/app/api/plumber.R"]
