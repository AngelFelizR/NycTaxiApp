let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-core-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        tibble stringr glue lubridate timeDate data_table qs2;
    };
  }
