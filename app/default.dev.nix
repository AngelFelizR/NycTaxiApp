# Dev shell for the UI service (phase 4): the root pin (nix/pkgs.nix) plus only
# the modules the app needs -- r-shiny (shiny, bslib, shinyjs, qs2, shinytest2,
# httr2, mirai), r-geo (leaflet, sf for ZonesShapes.qs2), r-plotting (ggplot2)
# and r-dev (testthat, plumber2 for dev/mock_api.R). Deliberately NOT
# r-api.nix: that one is pinned to the training environment and must never
# share a library path with the UI's R.
#
#   nix-shell app/default.dev.nix --run "Rscript app/app.R"
#   nix-shell app/default.dev.nix --run "Rscript app/tests/testthat.R"
#
# The root shell (nix-shell -A shell) also works: it auto-discovers every
# r-*.nix except r-api.nix, so it is a superset of this one.
let
  pkgs = import ../nix/pkgs.nix;
  systemPackages = import ../nix/system.nix;
  rShiny = import ../nix/r-shiny.nix;
  rGeo = import ../nix/r-geo.nix;
  rPlotting = import ../nix/r-plotting.nix;
  rDev = import ../nix/r-dev.nix;
  rModules = [ rShiny rGeo rPlotting rDev ];
in pkgs.mkShell {
  # Single merged library dir for every UI package (buildEnv), in front of
  # whatever the R wrapper would add.
  R_LIBS_SITE = pkgs.lib.concatMapStringsSep ":" (p: "${p}/library") rModules;
  buildInputs = [ pkgs.R systemPackages ] ++ rModules;
  LOCALE_ARCHIVE =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "${pkgs.glibcLocales}/lib/locale/locale-archive"
    else "";
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
  LC_TIME = "en_US.UTF-8";
  LC_MONETARY = "en_US.UTF-8";
  LC_PAPER = "en_US.UTF-8";
  FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
  FONTCONFIG_PATH = "${pkgs.fontconfig.out}/etc/fonts/";
  shellHook = ''
    export XDG_DATA_DIRS="${pkgs.dejavu_fonts}/share:${pkgs.freefont_ttf}/share:$XDG_DATA_DIRS"
    fc-cache -f 2>/dev/null || true
    # shinytest2 refuses to launch AppDriver when testthat believes we are on
    # CRAN; the flow test is a real browser test, not a CRAN check.
    export NOT_CRAN=true
  '';
}
