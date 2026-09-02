# NOTE: each R layer references a specific nix/r-*.nix file.
# default.nix does auto-discover these files, but here the ordering
# and separation are intentionally manual (per-layer caching).
# If you add a new r-*.nix, add its corresponding layer here too.

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

RUN mkdir -p /etc/nix && echo "sandbox = false" >> /etc/nix/nix.conf

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

# ── Layer 12: wire R up to actually find everything just built ──────────────
ENV R_LIBS_SITE="/nix/profiles/r-core/library:/nix/profiles/r-geo/library:/nix/profiles/r-ml/library:/nix/profiles/r-plotting/library:/nix/profiles/r-shiny/library:/nix/profiles/r-github/library" \
    PATH="${PATH}:/nix/profiles/system-packages/bin" \
    FONTCONFIG_FILE="/nix/profiles/system-packages/etc/fonts/fonts.conf" \
    FONTCONFIG_PATH="/nix/profiles/system-packages/etc/fonts/" \
    XDG_DATA_DIRS="/nix/profiles/system-packages/share:${XDG_DATA_DIRS}"

# ── Layer 13: app source + launch ────────────────────────────────────────────
COPY . /root/app
WORKDIR /root/app

EXPOSE 3838 22

RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

CMD ["/usr/sbin/sshd", "-D"]
