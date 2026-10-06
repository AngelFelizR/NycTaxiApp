# Production shell for the public share service (phase 7): everything it runs
# and nothing it is tested with. r-share.nix is the runtime set and
# r-shared.nix reads shared/*.yaml (docs/decisions/0003); nix/r-dev.nix is
# deliberately absent -- testthat and callr belong to default.dev.nix only.
#
#   nix-shell share/default.prod.nix --run "Rscript share/plumber.R"
let
  pkgs = import ../nix/pkgs.nix;
  systemPackages = import ../nix/system.nix { inherit pkgs; };
  rShare = import ../nix/r-share.nix { inherit pkgs; };
  rShared = import ../nix/r-shared.nix { inherit pkgs; };
  rEnv = pkgs.buildEnv { name = "r-share-prod"; paths = [ rShare rShared ]; };
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
