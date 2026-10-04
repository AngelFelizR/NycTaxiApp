let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-dev-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        testthat
        plumber2
        devtools
        roxygen2;
    };
  }
