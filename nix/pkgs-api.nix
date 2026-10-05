# API nixpkgs pin — same date as the training environment
# (r-projects/NycTaxi/default.nix), so the fitted workflows (qs2 + xgboost
# 1.7.x) load with the exact package versions they were written with.
# The Shiny app / root dev shell keep ./pkgs.nix (newer branch) instead.
# Changing this invalidates the API layers only (Dockerfile 9b, api/ shells).
import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2025-12-02.tar.gz") {}
