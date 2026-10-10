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
# The toolchain IS removed -- but from R's output, not from this list, which
# is why the two files share nix/r-slim.nix. openjdk (573 MB), gfortran (339),
# gcc (284) and glib-dev -> python3 (144) travel inside R's own output; see
# r-slim.nix for the four text files they are stripped from and why that is
# safe. ADR-0008 recorded the *idea* as rejected because it looked like it
# needed a patched R; ADR-0011 did it with remove-references-to instead.
#
# `pkgs` is a parameter so each Dockerfile passes the pin it already uses:
# pkgs-api.nix for the API, pkgs-app.nix for the UI, pkgs.nix for share.
{ pkgs ? import ./pkgs.nix }:
let
  # Same slim R as nix/system.nix. The pin slims it (nix/pkgs.nix applies
  # nix/slim-r-overlay.nix), so this layer only takes it -- building another
  # one here would put two Rs in the image, which is what ADR-0016 fixed. The
  # API Dockerfile passes pkgs-api.nix (R 4.5.2), the others the default, and
  # the strip is computed from the same pin that built R so its targets always
  # match what R actually references.
  inherit (pkgs) R;
in
  pkgs.buildEnv {
    name = "system-runtime-packages";
    paths = builtins.attrValues {
      inherit (pkgs)
        glibcLocales
        which
        # The healthcheck and the offline scripts probe HTTP with it. It lives
        # here, not in the root profile, because /root is 0700 and a non-root
        # container user cannot traverse it (phase 7 hardening).
        curl
        fontconfig
        dejavu_fonts
        freefont_ttf;
      inherit R;
    };
  }
