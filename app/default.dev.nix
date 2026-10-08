# Dev shell for the UI service (phases 4-6): ONE pin (nix/pkgs-app.nix) and
# ONE package set (nix/r-app.nix), plus the generic system layer.
#
#   nix-shell app/default.dev.nix --run "Rscript app/app.R"
#   nix-shell app/default.dev.nix --run "Rscript app/tests/testthat.R"
#   nix-shell app/default.dev.nix --run "./dev/e2e.sh"
#
# This is the shell the UI tests run in: the unit suite here, and the browser
# suite through ./dev/e2e.sh (Cypress comes from the image's PATH, not from
# this shell -- ADR-0012 kept it out of nix so an R change does not rebuild
# the browser).
#
# Deliberately NOT nix/r-api.nix: that one is pinned to the training
# environment and must never share a library path with the UI's R.
let
  pkgs = import ../nix/pkgs-app.nix;
  systemPackages = import ../nix/system.nix { inherit pkgs; };
  rApp = import ../nix/r-app.nix { inherit pkgs; };
in pkgs.mkShell {
  # Single merged library dir for every UI package (buildEnv), in front of
  # whatever the R wrapper would add. Everything the suite needs is in r-app:
  # there is no second library any more, since shinytest2 and the chromium it
  # drove left with the deletion commit ADR-0012 called for.
  R_LIBS_SITE = "${rApp}/library";
  buildInputs = [ systemPackages rApp ];
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
  '';
}
