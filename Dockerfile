# NOTE on Nix setup:
# - `nix-path` is pinned in Layer 2 to avoid Determinate's default
#   (nixpkgs=flake:flakehub.com/.../nixpkgs-weekly), which would otherwise
#   pull a different nixpkgs than nix/pkgs.nix at runtime.
# - Layer 13 builds `default.nix -A shell` so the stdenv bootstrap toolchain
#   (diffutils, gnumake, patchelf, etc.) is baked in, not fetched on first
#   `nix-shell` at runtime.
#
# NOTE: each R layer references a specific nix/r-*.nix file.
# default.nix does auto-discover these files, but here the ordering
# and separation are intentionally manual (per-layer caching).
# If you add a new r-*.nix, add its corresponding layer here too
# (Layer 9 will also pick it up automatically as a safety net).
#
# Some files under nix/ deliberately have NO layer here:
#   - nix/r-app.nix    the UI aggregate; it only chains the layers below, so
#                      baking it would add nothing but would pull in anything
#                      added to it later. The repo is mounted at runtime, so
#                      `nix-shell app/default.dev.nix` builds it on demand.
#   - nix/system-runtime.nix  the images' system layer (without `nix`); this
#                      is the development environment, so it keeps nix.
#   - nix/pkgs-app.nix / nix/r-app.nix  only app/default.dev.nix uses them and
#                      that shell is not baked.

FROM ubuntu:24.04

# ── Layer 1: apt base ────────────────────────────────────────────────────────
RUN apt update -y && \
    apt install -y locales curl openssh-server xz-utils && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# ── Layer 2: Nix installation (Docker optimized) ─────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | \
    sh -s -- install linux \
    --init none \
    --no-confirm

# The binary caches belong HERE, with the Nix installation. They used to sit
# in a layer between the R ones, which meant every R layer above them -- r-dev,
# r-geo, r-plotting, r-shiny -- compiled from source because the substitution
# was not configured yet: one local rebuild spent 40 minutes inside a single
# arrow.cc object. A cache configured after the work it should have saved
# saves nothing.
#
# The two public caches cover the generic half only: R 4.6.1 (r-slim) and the
# R packages of the 2025-12-02 API pin have no binary anywhere, so an
# invalidation recompiles them -- 747 s for R itself inside system.nix and
# 1099 s for 134 R packages inside r-api.nix, two of the four Nix layers. The
# last two lines point at a binary cache on the build host, fed from the image
# that was just built (infra/scripts/dev-image.sh); it is loopback, so a build
# without it costs one second of connection retries, not a failure. See ADR-0013.
RUN mkdir -p /etc/nix && \
    echo "sandbox = false" >> /etc/nix/nix.conf && \
    echo "nix-path = nixpkgs=https://github.com/rstats-on-nix/nixpkgs/archive/2026-09-28.tar.gz" >> /etc/nix/nix.conf && \
    echo "substituters = https://cache.nixos.org https://rstats-on-nix.cachix.org" >> /etc/nix/nix.conf && \
    echo "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0=" >> /etc/nix/nix.conf && \
    echo "extra-substituters = http://127.0.0.1:8093" >> /etc/nix/nix.conf && \
    echo "extra-trusted-public-keys = nyctaxi-dev-cache:tmG8F14/vTDOMkLWda0MC+V0C9Lm48HZBiVqjnfrvQg=" >> /etc/nix/nix.conf

ENV PATH="${PATH}:/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin" \
    BASH_ENV=/nix/var/nix/profiles/default/etc/profile.d/nix.sh \
    user=root

# ── Layer 3: direnv / nix-direnv (Positron integration) ─────────────────────
RUN nix-env -f '<nixpkgs>' -iA direnv nix-direnv && \
    nix-collect-garbage -d

RUN echo '. /nix/var/nix/profiles/default/etc/profile.d/nix.sh' >> /root/.bashrc

# ── Layer 3b: the slim-R strip and its overlay ───────────────────────────────
# These have to land BEFORE Layer 4: nix/pkgs.nix imports the overlay, which
# imports r-slim.nix, so `nix-instantiate`ing pkgs.nix needs both on disk. The
# service Dockerfiles copy nix/ as a whole and do not have this ordering to
# worry about.
COPY nix/r-slim.nix /root/nix/r-slim.nix
COPY nix/slim-r-overlay.nix /root/nix/slim-r-overlay.nix

# ── Layer 4: fetch and cache the nixpkgs tarball ─────────────────────────────
COPY nix/pkgs.nix /root/nix/pkgs.nix
RUN nix-instantiate --eval /root/nix/pkgs.nix && \
    nix-collect-garbage -d

# ── Layer 5: system packages (R, fontconfig, locales, fonts) ────────────────
# system.nix does `inherit (pkgs) R`: the pin already slims R via the overlay,
# so building another slim R here would put two Rs in the image (ADR-0016).
COPY nix/system.nix /root/nix/system.nix
RUN nix-build /root/nix/system.nix -o /nix/profiles/system-packages && \
    nix-collect-garbage -d

# ── Layer 6: Dev tools for package ───────────────────────────────────────────
COPY nix/r-dev.nix /root/nix/r-dev.nix
RUN nix-build /root/nix/r-dev.nix -o /nix/profiles/r-dev && \ 
    nix-collect-garbage -d

# ── Layer 7: geo / spatial packages ──────────────────────────────────────────
COPY nix/r-geo.nix /root/nix/r-geo.nix
RUN nix-build /root/nix/r-geo.nix -o /nix/profiles/r-geo && \
    nix-collect-garbage -d

# ── Layer 8: plotting packages ───────────────────────────────────────────────
COPY nix/r-plotting.nix /root/nix/r-plotting.nix
RUN nix-build /root/nix/r-plotting.nix -o /nix/profiles/r-plotting && \
    nix-collect-garbage -d

# ── Layer 9: Shiny app packages ─────────────────────────────────────────────
COPY nix/r-shiny.nix /root/nix/r-shiny.nix
RUN nix-build /root/nix/r-shiny.nix -o /nix/profiles/r-shiny && \
    nix-collect-garbage -d

# ── Layer 9b: API packages (plumber2, models, Postgres) ─────────────────────
# r-api.nix is built against nix/pkgs-api.nix (2025-12-02 pin) and is NOT part
# of the root shell (default.nix filters it out); building it here keeps API
# dependency changes on their own cache layer.
COPY nix/pkgs-api.nix /root/nix/pkgs-api.nix
COPY nix/r-api.nix /root/nix/r-api.nix
RUN nix-build /root/nix/r-api.nix -o /nix/profiles/r-api && \
    nix-collect-garbage -d

# ── Layer 9c: shared visual config reader (yaml) ────────────────────────────
# MUST land before Layer 10: default.nix auto-discovers nix/r-*.nix with
# readDir, so without this COPY the baked shell would silently come out
# without `yaml` and shared/load.R would fail at runtime.
COPY nix/r-shared.nix /root/nix/r-shared.nix
RUN nix-build /root/nix/r-shared.nix -o /nix/profiles/r-shared && \
    nix-collect-garbage -d

# ── Layer 9d: the shells the test jobs run in ───────────────────────────────
# CI runs the suites with `nix-shell <service>/default.dev.nix` inside this
# image, so those shells are built here rather than on a runner: the API shell
# adds testthat, yaml, jsonvalidate, V8, pkgload and covr on top of the r-api
# set Layer 9b already has, and the share shell adds plumber2 on top of the
# root one. Their expressions are copied next to /root/nix so the `../nix/...`
# they import resolves exactly as it does in the repository.
#
# The UI shell is deliberately NOT here: it is pinned to nix/pkgs-app.nix, so
# baking it would tie this layer to the UI's pin and the shell is built on
# demand from the mounted repository instead.
COPY nix/r-share.nix /root/nix/r-share.nix
COPY api/default.dev.nix /root/api/default.dev.nix
COPY share/default.dev.nix /root/share/default.dev.nix
RUN nix-build /root/api/default.dev.nix  -o /nix/profiles/shell-api  && \
    nix-build /root/share/default.dev.nix -o /nix/profiles/shell-share && \
    nix-collect-garbage -d

# ── Layer 10: realizar el shell completo (incluye stdenv toolchain) ─────────
COPY default.nix /root/default.nix
RUN nix-build /root/default.nix -A shell -o /nix/profiles/dev-shell && \
    nix-collect-garbage -d

EXPOSE 3838 22

RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config


# ── Layer 11: Cypress, for the UI's end-to-end tests (section 10, phase 8) ──
# Deliberately the LAST layer: anything above it that changes invalidates it,
# and nothing above it changes often. It has nothing to do with R.
#
# Three pieces, each for a reason:
#   * the Electron system libraries, from apt. This is an Ubuntu image and
#     Layer 1 already uses apt; the list is Cypress's own "required
#     dependencies" plus xvfb, which is what `cypress verify` was missing
#     first (spawn Xvfb ENOENT). Verified in-container before being written
#     down: `cypress verify` reports "Verified Cypress!".
#   * node, from nix (nix/node.nix), so the interpreter is pinned like
#     everything else here.
#   * Cypress from npm rather than pkgs.cypress: the pin marks
#     cypress-15.19.0 insecure, and granting permittedInsecurePackages means
#     editing nix/pkgs.nix -- which invalidates every layer above (ADR-0011).
#     `cypress install` downloads the binary explicitly because npm no longer
#     runs postinstall scripts by default, and `verify` failing here is the
#     point: a broken toolchain is caught at build time, not by a red test.
RUN apt update -y && apt install -y --no-install-recommends \
      xvfb xauth libgtk-3-0 libnss3 libgbm1 libasound2t64 libxss1 libxtst6 \
      libnotify4 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libcups2 \
      libpango-1.0-0 libcairo2 \
    && rm -rf /var/lib/apt/lists/*

COPY nix/node.nix /root/nix/node.nix
RUN nix-build /root/nix/node.nix -o /nix/profiles/node

ENV PATH="/nix/profiles/node/bin:/opt/npm/bin:${PATH}" \
    CYPRESS_CACHE_FOLDER=/opt/cypress-cache \
    npm_config_prefix=/opt/npm

RUN npm install --global cypress@15.19.0 && \
    /opt/npm/bin/cypress install && \
    /opt/npm/bin/cypress verify && \
    nix-collect-garbage -d

CMD ["/usr/sbin/sshd", "-D"]
