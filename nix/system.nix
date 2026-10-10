# Generic system layer: the R interpreter, locales, fonts and the handful of
# binaries every shell and every deployment image needs. Deliberately generic —
# a service image must be able to reuse this layer without inheriting another
# service's tools, which is why the R package sets (nix/r-*.nix) live
# elsewhere, and a test-only tool gets its own file rather than landing here.
#
# `pkgs` is a parameter so a caller can pin it: the UI passes pkgs-app.nix,
# the root dev shell passes ./pkgs.nix. The default keeps `nix-build
# nix/system.nix` (Dockerfile layer 5) working unchanged.
{ pkgs ? import ./pkgs.nix }:
let
  # R with the toolchain stripped out of its own output. It is NOT built here:
  # the pin already is (nix/pkgs.nix applies nix/slim-r-overlay.nix), so this
  # layer just takes it. Doing `import ./r-slim.nix` on top would produce a
  # SECOND derivation -- two Rs again, which is exactly the bug ADR-0016 fixed.
  # 1,340 MB of toolchain that a runtime never uses; see nix/r-slim.nix and
  # ADR-0011 for why it is safe and what it costs.
  inherit (pkgs) R;
in
  pkgs.buildEnv {
    name = "system-packages";
    paths = builtins.attrValues {
      inherit (pkgs)
        glibcLocales
        nix
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
