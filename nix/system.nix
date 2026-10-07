# Generic system layer: the R interpreter, locales, fonts and the handful of
# binaries every shell and every deployment image needs. Deliberately generic —
# a service image must be able to reuse this layer without inheriting another
# service's tools, which is why test-only tools (nix/test-tools.nix) and the
# R package sets (nix/r-*.nix) live elsewhere.
#
# `pkgs` is a parameter so a caller can pin it: the UI passes pkgs-app.nix,
# the root dev shell passes ./pkgs.nix. The default keeps `nix-build
# nix/system.nix` (Dockerfile layer 5) working unchanged.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "system-packages";
    paths = builtins.attrValues {
      inherit (pkgs)
        glibcLocales
        nix
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
