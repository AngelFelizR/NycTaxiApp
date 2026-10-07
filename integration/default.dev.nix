# Dev shell for the integration tests (an extension of the tree, §1.3 of the
# master document): they compare the three descriptions of the system --
# contract/openapi.yaml against the routes api/plumber.R registers and the
# paths the two clients call -- by reading files. Two packages and nothing
# else.
#
#   nix-shell default.dev.nix --run "Rscript tests/testthat.R"   (cwd = integration/)
#
# Deliberately NOT the root shell. That one builds six package sets (r-api is
# excluded but r-app, r-geo, r-plotting, r-shared, r-shiny and r-dev are not),
# which means compiling a dependency of packages these tests never touch --
# and the CI job died once doing exactly that while other jobs were building.
# Nothing here reads the database, the cache or a model, so the lighter shell
# is also the more honest one.
let
  pkgs = import ../nix/pkgs.nix;
in pkgs.mkShell {
  buildInputs = [
    pkgs.R
    pkgs.rPackages.testthat
    pkgs.rPackages.yaml
  ];
  LOCALE_ARCHIVE =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "${pkgs.glibcLocales}/lib/locale/locale-archive"
    else "";
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
}
