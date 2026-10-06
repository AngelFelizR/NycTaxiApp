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
        freefont_ttf
        # Headless browser for the shinytest2 flow test (phase 4 criterion):
        # chromote looks for `chromium` on the PATH (CHROMOTE_CHROME overrides
        # it). Baking it in keeps the test runnable inside the dev container.
        chromium;
    };
  }
