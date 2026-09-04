let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-dev-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        devtools;
    };
  }
