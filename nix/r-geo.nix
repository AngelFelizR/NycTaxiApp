# Spatial stack (Leaflet map + ZonesShapes.qs2 geometry). `pkgs` is a
# parameter: see nix/r-shiny.nix.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "r-geo-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        sf leaflet units;
    };
  }
