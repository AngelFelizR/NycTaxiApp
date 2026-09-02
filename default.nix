let
  # Pin unificado
  pkgs = import ./nix/pkgs.nix;
  # Entornos de sistema
  systemPackages = import ./nix/system.nix;
  # Paquetes de R (cada uno es ahora un buildEnv de salida única,
  # igual que los layers de nix-build en el Dockerfile)
  rCorePkgs   = import ./nix/r-core.nix;
  rMlPkgs     = import ./nix/r-ml.nix;
  rGeoPkgs    = import ./nix/r-geo.nix;
  rPlotPkgs   = import ./nix/r-plotting.nix;
  rShinyPkgs  = import ./nix/r-shiny.nix;
  rGithubPkgs = import ./nix/r-github.nix;

  shell = pkgs.mkShell {
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
    buildInputs = [
      systemPackages
      rCorePkgs
      rMlPkgs
      rGeoPkgs
      rPlotPkgs
      rShinyPkgs
      rGithubPkgs
    ];
  };
in
{
  inherit pkgs shell;
}
