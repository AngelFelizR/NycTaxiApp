# syntax=docker/dockerfile:1
###############################################################################
# Shiny UI image (master doc 1.1, 6, 8.6).
#
# Multi-stage, same shape as share/Dockerfile: a Nix stage assembles the
# closure, a second stage extracts it. The image carries app/ and shared/ only
# -- models and datasets are mounted read-only at runtime (4.5, 15), and
# ShinyProxy injects TAXI_API_URL / API_INTERNAL_KEY (8.3).
#
#   docker build -f app/Dockerfile -t ghcr.io/angelfelizr/nyc-taxi-shiny:latest .
#
# `withDev = false` drops nix/r-dev.nix: no testthat, no callr, no plumber2
# (plumber2 only exists for dev/mock_api.R, which is not deployed) and no
# pkgload. shinytest2 left nix/r-shiny.nix for nix/test-tools.nix (ADR-0007),
# so the UI image no longer ships a browser driver it never runs; the browser
# itself never did -- chromium lives in nix/test-tools.nix too and no image
# imports it.
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

# pkgs-app.nix is r-app.nix's own default pin, so only `withDev` is passed.
RUN nix-build nix/system.nix -o /out-system && \
    nix-build -E '(import ./nix/r-app.nix { withDev = false; })' -o /out-rapp && \
    nix-store -qR /out-system /out-rapp | sort -u > /closure

RUN tar -C / -czf /closure.tar.gz -T /closure

# ────────────────────────────────────────────────────────── stage 2: runtime
FROM ${NIX_IMAGE} AS runtime

COPY --from=build /closure.tar.gz /tmp/closure.tar.gz
RUN tar -C / -xzf /tmp/closure.tar.gz && rm /tmp/closure.tar.gz

COPY --from=build /out-system /opt/system
COPY --from=build /out-rapp    /opt/r

ENV PATH="/opt/system/bin:${PATH}" \
    LOCALE_ARCHIVE="/opt/system/lib/locale/locale-archive" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    LC_MONETARY="en_US.UTF-8" \
    LC_PAPER="en_US.UTF-8" \
    FONTCONFIG_FILE="/opt/system/etc/fonts/fonts.conf" \
    FONTCONFIG_PATH="/opt/system/etc/fonts" \
    XDG_DATA_DIRS="/opt/system/share:/opt/system/lib/X11/xkb" \
    # /opt/r-lib holds taxiapp, installed below from the source in the image
    # (ADR-0007); /opt/r/library is the Nix package set.
    R_LIBS_SITE="/opt/r-lib:/opt/r/library"

# Layout matters. app.R runs with cwd = /app/app and R/shared_config.R looks
# for ../shared/load.R, so shared/ has to be its sibling -- the same shape the
# repository has and the one app_data_dir() and shared_dir() resolve by
# candidate.
WORKDIR /app
COPY app/ /app/app/
COPY shared/ /app/shared/

# ADR-0007: the app runs an installed package. Installed AFTER shared/ is in
# place because R/shared_config.R sources shared/load.R and strings.R bakes
# its label_curve_* aliases from it at install time -- changing a curve label
# has to invalidate this layer, or the card would show the old text. Before
# USER below: /opt/r-lib has to be writable. pkgload is not here; the image
# takes the library() branch precisely because the package is installed.
RUN mkdir -p /opt/r-lib \
 && R CMD INSTALL --library=/opt/r-lib /app/app \
 && rm -rf /tmp/* /tmp/..?* /tmp/.[!.]*


# Phase 7 hardening: run unprivileged (ADR-004). The base image has no
# useradd and /etc/passwd is a symlink into the Nix store, so a numeric id
# with an explicit HOME is the portable choice. Everything R writes goes to
# /tmp, which docker-compose.prod.yml declares as a tmpfs; HOME points there
# so fontconfig, bslib and Shiny's session files have somewhere to land.
# curl is used by the healthcheck and comes from nix/system.nix (/opt/system),
# not from /root/.nix-profile, which a non-root user cannot traverse.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache
USER 65534:65534

EXPOSE 3838
CMD ["sh", "-c", "cd /app/app && exec Rscript -e 'shiny::runApp(\".\", host = \"0.0.0.0\", port = 3838)'"]
