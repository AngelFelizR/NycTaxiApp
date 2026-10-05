# Dev shell for the API service (phase 1): R 4.5.2 + the r-api package set,
# both from nix/pkgs-api.nix (2025-12-02, the training pin). The root shell
# deliberately excludes r-api.nix, so this file is the entry point to run the
# API and its tests on their own:
#   nix-shell api/default.dev.nix --run "Rscript api/plumber.R"
#   nix-shell api/default.dev.nix --run "Rscript api/tests/testthat.R"
let
  pkgs = import ../nix/pkgs-api.nix;
  rApi = import ../nix/r-api.nix;
in pkgs.mkShell {
  # Single merged library dir for every API package (buildEnv), in front of
  # whatever the R wrapper would add.
  R_LIBS_SITE = "${rApi}/library";
  buildInputs = [ pkgs.R rApi ];
  LOCALE_ARCHIVE =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "${pkgs.glibcLocales}/lib/locale/locale-archive"
    else "";
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
  # fork()-safe: POST /experiments forks a child to compute the two model
  # trajectories (R/endpoints/experiments.R). libgomp is already loaded when
  # R starts and reads OMP_NUM_THREADS there, so it has to be part of the
  # environment instead of a Sys.setenv() inside plumber.R. A fork after
  # OpenMP has built its thread pool deadlocks the child in futex_wait.
  OMP_NUM_THREADS = "1";
  OPENBLAS_NUM_THREADS = "1";
  VECLIB_MAXIMUM_THREADS = "1";
}
