# API nixpkgs pin — same date as the training environment
# (r-projects/NycTaxi/default.nix), so the fitted workflows (qs2 + xgboost
# 1.7.x) load with the exact package versions they were written with.
# The Shiny app / root dev shell keep ./pkgs.nix (newer branch) instead.
# Changing this invalidates the API layers only (Dockerfile 9b, api/ shells).
#
# The overlay makes this pin's `R` the slim one (nix/r-slim.nix), for the
# same reason as ./pkgs.nix: the compiled R packages of nix/r-api.nix have to
# reference the same R the system layer ships, or the toolchain comes back
# through their RPATH. ADR-0016. Deliberately NOT a function: every caller
# does `import ./pkgs-api.nix` and expects a set.
let
  base = fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2025-12-02.tar.gz";
in
  import base { overlays = [ (import ./slim-r-overlay.nix) ]; }
