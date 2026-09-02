let
  pkgs = import ./pkgs.nix;
in
  pkgs.buildEnv {
    name = "system-packages";
    paths = builtins.attrValues {
      inherit (pkgs)
        glibcLocales
        nix
        R
        which
        fontconfig
        dejavu_fonts
        freefont_ttf;
    };
  }
