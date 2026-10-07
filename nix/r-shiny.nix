# Shiny stack for the UI. `pkgs` is a parameter so nix/r-app.nix can pin it to
# pkgs-app.nix while the root dev shell passes ./pkgs.nix; the default keeps
# `nix-build nix/r-shiny.nix` (Dockerfile layer 9) working unchanged.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "r-shiny-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        # Normal shiny
        shiny
        bslib

        # Phase 4 (UI setup): visibility of the validation hints, preload of
        # ZonesShapes.qs2 (same file the API reads) and the flow test.
        shinyjs
        qs2

        # Connecting to model API
        httr2
        mirai
        promises
        jsonlite;
    };
  }
