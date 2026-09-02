let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-geo-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        sf leaflet units;
    };
  }
