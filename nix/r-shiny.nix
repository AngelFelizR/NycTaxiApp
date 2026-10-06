let
  pkgs = import ./pkgs.nix;
in
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
        shinytest2

        # Connecting to model API
        httr2
        mirai
        promises
        jsonlite;
    };
  }
