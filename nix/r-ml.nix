let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-ml-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        tidymodels xgboost recipes embed;
    };
  }
