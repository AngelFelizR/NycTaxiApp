let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "r-plotting-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        sysfonts showtext ggplot2 ggtext ggrepel ggiraph scales;
    };
  }
