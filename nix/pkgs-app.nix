# UI nixpkgs pin — the branch the Shiny app builds against.
#
# Today it points at the SAME tarball as ./pkgs.nix, so nothing rebuilds
# (builtins.fetchTarball keys the store path by URL: verified identical
# /nix/store/...-R-4.6.1 for both files). The point of the split is the seam:
# bumping this file invalidates only the UI layers (r-app.nix and its
# consumers), never nix/system.nix or the API.
#
# CAUTION: nix/system.nix provides the R binary that loads these packages, so
# if this pin ever moves to a different nixpkgs branch, system.nix has to move
# with it (pass the same pkgs to both) or the libraries will not load.
#
# The overlay makes this pin's `R` the slim one (nix/r-slim.nix): the UI ships
# ~106 R packages, 63 of them compiled, and without it every one of those .so
# pointed at a second, unstripped R -- ADR-0016. Deliberately NOT a function:
# every caller does `import ./pkgs-app.nix` and expects a set.
let
  base = fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2026-09-28.tar.gz";
in
  import base { overlays = [ (import ./slim-r-overlay.nix) ]; }
