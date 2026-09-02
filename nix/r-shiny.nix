let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-shiny-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        shiny golem bslib;
    };
  }
