# Production shell for the API (phase 7): the same pin and the same package
# set the deployment image runs, with nothing a deployment never executes.
# It exists so a single service can be run and inspected on its own, without
# the development conveniences:
#
#   nix-shell api/default.prod.nix --run "Rscript api/plumber.R"
#
# Keep in sync with the API's Dockerfile layer (that one builds nix/r-api.nix
# directly). Deliberately NOT nix/r-dev.nix: testthat/callr belong to the dev
# shell, and OMP_NUM_THREADS stays exported -- libgomp reads it when R starts,
# and a fork after OpenMP built its pool deadlocks the trajectory child
# (see api/plumber.R and api/default.dev.nix).
let
  pkgs = import ../nix/pkgs-api.nix;
  systemPackages = import ../nix/system.nix { inherit pkgs; };
  rApi = import ../nix/r-api.nix;
in pkgs.mkShell {
  R_LIBS_SITE = "${rApi}/library";
  buildInputs = [ systemPackages rApi ];
  LOCALE_ARCHIVE =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "${pkgs.glibcLocales}/lib/locale/locale-archive"
    else "";
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
  OMP_NUM_THREADS = "1";
  OPENBLAS_NUM_THREADS = "1";
  VECLIB_MAXIMUM_THREADS = "1";
}
