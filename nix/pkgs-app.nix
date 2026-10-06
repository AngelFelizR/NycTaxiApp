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
import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2026-09-28.tar.gz") {}
