# Packages required by the plumber2 API in api/ (phase 1+).
# Built by Dockerfile layer 9b and loaded by api/default.dev.nix; the root
# default.nix deliberately filters this module out (separate pin).
# Keep UI-only packages out of here: this module is the API's own layer.
#
# Pin: pkgs-api.nix (2025-12-02, the training environment) so the fitted
# workflows load with the versions they were written with (xgboost 1.7.x,
# qs2 0.1.6, R 4.5.2). The only exception is mori, which does not exist in
# that pin: the prebuilt copy from the newer ./pkgs.nix cannot load in
# R 4.5.2 ("built under R version 4.6.1", undefined symbol R_getAttributes),
# so it is built from the same CRAN source against this pin's R instead
# (same buildRPackage approach as NycTaxi's r-custom.nix for corrcat/pins).
let
  pkgs = import ./pkgs-api.nix;
  mori = pkgs.rPackages.buildRPackage {
    name = "mori";
    src = pkgs.fetchurl {
      url = "mirror://cran/mori_0.2.2.tar.gz";
      sha256 = "sha256-8jHpFaq2Va0xEmwCFFcvMod16wA6Z+jwbmBMrB6+NTk=";
    };
  };
in
  pkgs.buildEnv {
    name = "r-api-pkgs";
    paths = (with pkgs.rPackages; [
      # HTTP server
      plumber2
      jsonlite
      glue
      logger

      # Model files and shared memory
      qs2
      mori

      # PostgreSQL
      pool
      DBI
      RPostgres

      # Redis (sensitivity cache; rate limits and counters from phase 3 on)
      redux

      # Hashing (ip_hash, resume_code)
      digest

      # Loading a fitted tidymodels workflow requires the whole stack
      workflows
      parsnip
      recipes
      hardhat
      dials
      tune
      butcher
      # AcceptRejectPolicyFitted carries a tailor probability-threshold
      # post-processor (adjust_probability_threshold): predict() needs it.
      tailor
      xgboost

      # Data manipulation used by the endpoints
      dplyr
      tibble
      stringr
      lubridate
      rlang
      data_table
      # Trip dataset lookup for /sensitivity and /trips/sample
      # (NycTrips2024_sample_week.parquet)
      nanoparquet

      # Recipe steps used by the fitted models (step_downsample)
      themis
      # step_harmonic / step_lencode (both fitted recipes) and the US*Day
      # holiday helpers referenced inside the recipes' step_mutate quosures
      embed
      timeDate

      # NOTE: testthat is NOT here. This module is also built by Dockerfile
      # layer 9b for the production image, and no deployment ever runs a test;
      # api/default.dev.nix adds it to the development shell instead.
      httr2
    ]);
  }
