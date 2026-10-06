# Chart stack for the UI (cumulative curves, sensitivity grid). `pkgs` is a
# parameter: see nix/r-shiny.nix.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "r-plotting-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        sysfonts
        showtext
        ggplot2
        ggtext
        ggrepel
        scales
        ggiraph;
    };
  }
