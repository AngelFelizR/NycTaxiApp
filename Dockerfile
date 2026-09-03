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
# (Layer 13 will also pick it up automatically as a safety net).

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

RUN mkdir -p /etc/nix && \
    echo "sandbox = false" >> /etc/nix/nix.conf && \
    echo "nix-path = nixpkgs=https://github.com/rstats-on-nix/nixpkgs/archive/2025-12-02.tar.gz" >> /etc/nix/nix.conf

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

# ── Layer 6: core R / tidyverse-style packages ───────────────────────────────
COPY nix/r-core.nix /root/nix/r-core.nix
RUN nix-build /root/nix/r-core.nix -o /nix/profiles/r-core && \
    nix-collect-garbage -d

# ── Layer 7: geo / spatial packages ──────────────────────────────────────────
COPY nix/r-geo.nix /root/nix/r-geo.nix
RUN nix-build /root/nix/r-geo.nix -o /nix/profiles/r-geo && \
    nix-collect-garbage -d

# ── Layer 8: ML / modelling packages ─────────────────────────────────────────
COPY nix/r-ml.nix /root/nix/r-ml.nix
RUN nix-build /root/nix/r-ml.nix -o /nix/profiles/r-ml && \
    nix-collect-garbage -d

# ── Layer 9: plotting packages ───────────────────────────────────────────────
COPY nix/r-plotting.nix /root/nix/r-plotting.nix
RUN nix-build /root/nix/r-plotting.nix -o /nix/profiles/r-plotting && \
    nix-collect-garbage -d

# ── Layer 10: Shiny app packages ─────────────────────────────────────────────
COPY nix/r-shiny.nix /root/nix/r-shiny.nix
RUN nix-build /root/nix/r-shiny.nix -o /nix/profiles/r-shiny && \
    nix-collect-garbage -d

# ── Layer 11: custom-built packages (pins, roxygen2) ─────────────────────────
COPY nix/r-github.nix /root/nix/r-github.nix
RUN nix-build /root/nix/r-github.nix -o /nix/profiles/r-github && \
    nix-collect-garbage -d

# ── Layer 12: dev-only R packages (golem, devtools) ──────────────────────────
COPY nix/r-dev.nix /root/nix/r-dev.nix
RUN nix-build /root/nix/r-dev.nix -o /nix/profiles/r-dev && \
    nix-collect-garbage -d

# ── Layer 13: realizar el shell completo (incluye stdenv toolchain) ─────────
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
