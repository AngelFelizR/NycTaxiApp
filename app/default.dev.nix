# Dev shell for the UI service (phases 4-6): ONE pin (nix/pkgs-app.nix) and
# ONE package set (nix/r-app.nix), plus the generic system layer and the
# test-only browser that the shinytest2 flow test drives.
#
#   nix-shell app/default.dev.nix --run "Rscript app/app.R"
#   nix-shell app/default.dev.nix --run "Rscript app/tests/testthat.R"
#
# This is the shell the UI tests must run in: the root shell deliberately
# leaves out nix/test-tools.nix, so under `nix-shell` at the repo root the
# flow test skips with "no Chrome/Chromium on the PATH".
#
# Deliberately NOT nix/r-api.nix: that one is pinned to the training
# environment and must never share a library path with the UI's R.
let
  pkgs = import ../nix/pkgs-app.nix;
  systemPackages = import ../nix/system.nix { inherit pkgs; };
  rApp = import ../nix/r-app.nix { inherit pkgs; };
  testTools = import ../nix/test-tools.nix { inherit pkgs; };
in pkgs.mkShell {
  # Single merged library dir for every UI package (buildEnv), in front of
  # whatever the R wrapper would add. testTools is a second library since
  # shinytest2 moved out of nix/r-shiny.nix (ADR-0007) -- R only sees what
  # R_LIBS_SITE names, so leaving it out made the flow test skip with
  # "{shinytest2} is not installed" while the package was right there in the
  # shell.
  R_LIBS_SITE = "${rApp}/library:${testTools}/library";
  buildInputs = [ systemPackages rApp testTools ];
  LOCALE_ARCHIVE =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "${pkgs.glibcLocales}/lib/locale/locale-archive"
    else "";
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
  LC_TIME = "en_US.UTF-8";
  LC_MONETARY = "en_US.UTF-8";
  LC_PAPER = "en_US.UTF-8";
  LC_MEASUREMENT = "en_US.UTF-8";
  FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
  FONTCONFIG_PATH = "${pkgs.fontconfig.out}/etc/fonts/";
  shellHook = ''
    export XDG_DATA_DIRS="${pkgs.dejavu_fonts}/share:${pkgs.freefont_ttf}/share:$XDG_DATA_DIRS"
    fc-cache -f 2>/dev/null || true
    # shinytest2 refuses to launch AppDriver when testthat believes we are on
    # CRAN. The flow test also sets NOT_CRAN itself; this covers `Rscript -e`
    # runs from this shell.
    export NOT_CRAN=true
  '';
}
