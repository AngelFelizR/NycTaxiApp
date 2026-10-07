# Runtime system layer for the DEPLOYMENT IMAGES only.
#
# Same as nix/system.nix minus `nix`. The images are built FROM nixos/nix, so
# the CLI is already there; carrying a second copy through the closure cost
# 206 MB per image (measured: system.nix closes at 2608 MB, of which nix's own
# closure is 206 MB across 63 paths). Nothing in a container ever runs nix, so
# it is pure duplication -- unlike the rest of the layer, which is exercised by
# the healthcheck (`curl`), by R, and by `LANG=en_US.UTF-8` (`glibcLocales`).
#
# The development shells keep importing nix/system.nix: a shell *is* where you
# run nix. Which means this file and that one differ by one package on purpose
# -- there is no behavioural difference between the two at runtime, only an
# unused binary, which is exactly what makes the split safe. The image's own
# expectations (FONTCONFIG_FILE, LOCALE_ARCHIVE, /opt/system/bin on PATH) are
# unchanged.
#
# Deliberately NOT the toolchain. openjdk (573 MB), gfortran (339), gcc (284)
# and python3 (144) also look removable, but they are not in this expression:
# they come out of R's own output, which references them from its buildInputs.
# Dropping them means rebuilding R with removeReferencesTo -- a different
# project, with `R CMD INSTALL` and R's startup to revalidate. Recorded as
# rejected in ADR-0008 rather than half-done here.
#
# `pkgs` is a parameter so each Dockerfile passes the pin it already uses:
# pkgs-api.nix for the API, pkgs-app.nix for the UI, pkgs.nix for share.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "system-runtime-packages";
    paths = builtins.attrValues {
      inherit (pkgs)
        glibcLocales
        R
        which
        # The healthcheck and the offline scripts probe HTTP with it. It lives
        # here, not in the root profile, because /root is 0700 and a non-root
        # container user cannot traverse it (phase 7 hardening).
        curl
        fontconfig
        dejavu_fonts
        freefont_ttf;
    };
  }
