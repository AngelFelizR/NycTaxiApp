# Dev shell for the share service (phase 6): R from the root pin plus
# nix/r-share.nix (plumber2, httr2, patchwork, ragg, redux) and nix/r-dev.nix
# (testthat, callr). Deliberately NOT r-api.nix (different R) and not r-app.nix
# (share serves HTML and a PNG, it never renders a Shiny session).
#
#   nix-shell share/default.dev.nix --run "Rscript share/plumber.R"
#   nix-shell share/default.dev.nix --run "Rscript share/tests/testthat.R"
let
  pkgs = import ../nix/pkgs.nix;
  systemPackages = import ../nix/system.nix { inherit pkgs; };
  rShare = import ../nix/r-share.nix { inherit pkgs; };
  rDev = import ../nix/r-dev.nix { inherit pkgs; };
  # shared/*.yaml (curve spec + brand palette) read through shared/load.R.
  rShared = import ../nix/r-shared.nix { inherit pkgs; };
  # One merged library tree: R_LIBS_SITE has a single root (see app/ and api/),
  # and the phase-7 image keeps inheriting r-share.nix alone, without the
  # test-only tooling of r-dev.nix.
  rEnv = pkgs.buildEnv { name = "r-share-dev"; paths = [ rShare rDev rShared ]; };
in pkgs.mkShell {
  R_LIBS_SITE = "${rEnv}/library";
  buildInputs = [ pkgs.R systemPackages rEnv ];
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
  '';
}
