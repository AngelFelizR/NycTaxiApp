# R packages for the public share service (phase 6). Separate from r-app.nix
# because share is its own container (5.10): no Postgres, no models, no Shiny.
#
# Consumed by share/default.dev.nix and, in phase 7, by the share image. Not
# named r-*.nix's sibling by accident -- see nix/r-app.nix for the UI.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "r-share-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        # Serving the two public routes.
        plumber2
        jsonlite
        # Talking to the private API (X-Internal-Key + X-Client-IP).
        httr2
        # The PNG: 1200x630 with three cumulative curves and one big label.
        patchwork
        ragg
        # Redis: PNG bytes (24h TTL) and the share_views counters.
        redux;
    };
  }
