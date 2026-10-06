# Everything the Shiny app needs, as ONE expression.
#
# A deployment image for the UI (phase 7) builds `nix-build nix/r-app.nix`
# and nothing else: it must not inherit the API's modelling stack, nor the
# dev-only tooling of r-dev.nix beyond what the app actually loads at runtime.
#
# Components take `pkgs` as an argument so this file can pin them to
# pkgs-app.nix while the root dev shell passes ./pkgs.nix instead.
{ pkgs ? import ./pkgs-app.nix }:
let
  rShiny     = import ./r-shiny.nix     { inherit pkgs; };
  rGeo       = import ./r-geo.nix       { inherit pkgs; };
  rPlotting  = import ./r-plotting.nix  { inherit pkgs; };
  rDev       = import ./r-dev.nix       { inherit pkgs; };
  # shared/*.yaml: the curve spec and the brand palette read through
  # shared/load.R (docs/decisions/0003).
  rShared    = import ./r-shared.nix    { inherit pkgs; };
in
  pkgs.buildEnv {
    name = "r-app-pkgs";
    paths = [ rShiny rGeo rPlotting rDev rShared ];
  }
