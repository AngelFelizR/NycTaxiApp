# Production shell for the UI (phase 7): R from the app's own pin plus the
# runtime-only package set. Same shell the deployment image runs, so a single
# service can be exercised on its own without the development extras:
#
#   nix-shell app/default.prod.nix --run "Rscript app/app.R"
#
# `withDev = false` drops nix/r-dev.nix (testthat, callr and plumber2): the
# app never loads them at runtime -- plumber2 only exists there for
# dev/mock_api.R, which no deployment ships. Keep this in sync with the UI's
# Dockerfile layer.
let
  pkgs = import ../nix/pkgs-app.nix;
  systemPackages = import ../nix/system.nix { inherit pkgs; };
  rApp = import ../nix/r-app.nix { inherit pkgs; withDev = false; };
in pkgs.mkShell {
  R_LIBS_SITE = "${rApp}/library";
  # The image installs taxiapp and takes the library() branch; this shell has
  # no installed copy, so app/app.R falls back to pkgload::load_all(). Kept
  # out of nix/r-app.nix -- that one is the image's layer.
  buildInputs = [ systemPackages rApp pkgs.rPackages.pkgload ];
  LOCALE_ARCHIVE =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then "${pkgs.glibcLocales}/lib/locale/locale-archive"
    else "";
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
  LC_MONETARY = "en_US.UTF-8";
  LC_PAPER = "en_US.UTF-8";
  # shinytest2 refuses to launch AppDriver when testthat thinks we are on
  # CRAN. Not needed here (no browser in production), kept so an accidental
  # flow test in this shell fails loudly instead of silently skipping.
  NOT_CRAN = "true";
  FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
  FONTCONFIG_PATH = "${pkgs.fontconfig.out}/etc/fonts/";
  shellHook = ''
    export XDG_DATA_DIRS="${pkgs.dejavu_fonts}/share:${pkgs.freefont_ttf}/share:$XDG_DATA_DIRS"
    fc-cache -f 2>/dev/null || true
  '';
}
