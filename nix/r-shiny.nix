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

        # Connecting to model API
        httr2
        mirai;
    };
  }
