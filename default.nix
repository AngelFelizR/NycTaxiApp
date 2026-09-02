let
  pkgs = import ./nix/pkgs.nix;
  systemPackages = import ./nix/system.nix;

  dirEntries = builtins.readDir ./nix;

  rModuleFiles = builtins.filter
    (name: pkgs.lib.hasPrefix "r-" name && pkgs.lib.hasSuffix ".nix" name)
    (builtins.attrNames dirEntries);

  rModuleList = map (file: import (./nix + "/${file}")) rModuleFiles;

  shell = pkgs.mkShell {
    R_LIBS_SITE = pkgs.lib.concatMapStringsSep ":" (p: "${p}/library") rModuleList;
    buildInputs = [ systemPackages ] ++ rModuleList;
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
  };
in
{
  inherit pkgs shell;
}
