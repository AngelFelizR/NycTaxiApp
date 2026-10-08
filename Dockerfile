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
# Two files under nix/ deliberately have NO layer here:
#   - nix/r-app.nix    the UI aggregate; it only chains the layers below, so
#                      baking it would add nothing but would pull in anything
#                      added to it later. The repo is mounted at runtime, so
#                      `nix-shell app/default.dev.nix` builds it on demand.
#   - nix/test-tools.nix  the shinytest2 browser (chromium, 1.3 GB). Keeping
#                      it out of every layer is the point: no image ships a
#                      browser it never runs. The UI flow test fetches it from
#                      the binary cache on first use, under
#                      `nix-shell app/default.dev.nix`.
#   - nix/system-runtime.nix  the images' system layer (without `nix`); this
#                      is the development environment, so it keeps nix.
#   - nix/pkgs-app.nix / nix/r-app.nix  only app/default.dev.nix uses them and
#                      that shell is not baked (see test-tools above).

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
RUN mkdir -p /etc/nix && \
    echo "sandbox = false" >> /etc/nix/nix.conf && \
    echo "nix-path = nixpkgs=https://github.com/rstats-on-nix/nixpkgs/archive/2026-09-28.tar.gz" >> /etc/nix/nix.conf && \
    echo "substituters = https://cache.nixos.org https://rstats-on-nix.cachix.org" >> /etc/nix/nix.conf && \
    echo "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= rstats-on-nix.cachix.org-1:vdiiVgocg6WeJrODIqdprZRUrhi1JzhBnXv7aWI6+F0=" >> /etc/nix/nix.conf

ENV PATH="${PATH}:/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin" \
    BASH_ENV=/nix/var/nix/profiles/default/etc/profile.d/nix.sh \
    user=root

# ── Layer 3: direnv / nix-direnv (Positron integration) ─────────────────────
RUN nix-env -f '<nixpkgs>' -iA direnv nix-direnv && \
    nix-collect-garbage -d

RUN echo '. /nix/var/nix/profiles/default/etc/profile.d/nix.sh' >> /root/.bashrc

# ── Layer 4: fetch and cache the nixpkgs tarball ─────────────────────────────
COPY nix/pkgs.nix /root/nix/pkgs.nix
RUN nix-instantiate --eval /root/nix/pkgs.nix && \
    nix-collect-garbage -d

# ── Layer 5: system packages (R, fontconfig, locales, fonts) ────────────────
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
# The UI shell is deliberately NOT here: it would pull nix/test-tools.nix
# (chromium, 1.3 GB), and the header of this file says no layer carries a
# browser. The flow test fetches it from the binary cache on first use.
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

CMD ["/usr/sbin/sshd", "-D"]
