# Shared nixpkgs pin — imported by all other nix files
# Changing this invalidates ALL layers; change it rarely.
#
# The overlay makes this pin's `R` the slim one (nix/r-slim.nix): one R per
# pin, referenced by the system layer AND by every rPackage, so a compiled
# package's RPATH cannot drag an unstripped R -- and with it openjdk and
# glib-dev -> python3 -- back into an image. ADR-0016. Deliberately NOT a
# function: every caller does `import ./pkgs.nix` and expects a set.
let
  base = fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2026-09-28.tar.gz";
in
  import base { overlays = [ (import ./slim-r-overlay.nix) ]; }
