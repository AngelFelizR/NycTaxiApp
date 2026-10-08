# NOTE: default.nix auto-discovers every r-*.nix file (see readDir below).
# If you add a new r-*.nix here, the Dockerfile does NOT pick it up
# automatically: you need to add its own COPY/RUN layer there manually.

let
  pkgs = import ./nix/pkgs.nix;
  systemPackages = import ./nix/system.nix { inherit pkgs; };

  dirEntries = builtins.readDir ./nix;

  # Two files under nix/ are intentionally NOT part of this shell:
  #
  #  - r-api.nix: pinned to nix/pkgs-api.nix (2025-12-02 / R 4.5.2, the
  #    training environment) and mixing its libraries here would put
  #    R-4.5.2-compiled packages in front of this shell's R 4.6.1 ones
  #    (R_LIBS_SITE is ordered by file name). Consumed by Dockerfile layer
  #    9b and api/default.dev.nix only.
  #  - r-app.nix: the AGGREGATE for the UI (r-shiny + r-geo + r-plotting +
  #    r-dev pinned to nix/pkgs-app.nix). Importing it here would duplicate
  #    every module the filter below already adds. Consumed by
  #    app/default.dev.nix.
  #
  # A test-only tool is not named r-*.nix on purpose: this shell has to stay
  # free of them, or the baked dev-shell profile grows by the closure of
  # whatever the tests happen to need -- chromium was 1.3 GB while the flow
  # test drove it, and it went with shinytest2 when the browser suite moved to
  # Cypress. The browser suite runs under `nix-shell app/default.dev.nix`.
  rModuleFiles = builtins.filter
    (name:
      pkgs.lib.hasPrefix "r-" name &&
      pkgs.lib.hasSuffix ".nix" name &&
      name != "r-api.nix" &&
      name != "r-app.nix")
    (builtins.attrNames dirEntries);

  # Every module takes `pkgs` so a caller can pin it; the root shell passes
  # ./pkgs.nix (the default anyway) to keep one consistent R for the shell.
  rModuleList = map (file: import (./nix + "/${file}") { inherit pkgs; }) rModuleFiles;

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
    # fork()-safe: same reason as in api/default.dev.nix -- libgomp reads
    # OMP_NUM_THREADS when R starts, so a process that will fork() (the API's
    # async create) must inherit it from the shell rather than from
    # Sys.setenv(), which would be too late.
    OMP_NUM_THREADS = "1";
    OPENBLAS_NUM_THREADS = "1";
    VECLIB_MAXIMUM_THREADS = "1";
    shellHook = ''
      export XDG_DATA_DIRS="${pkgs.dejavu_fonts}/share:${pkgs.freefont_ttf}/share:$XDG_DATA_DIRS"
      fc-cache -f 2>/dev/null || true
    '';
  };
in
{
  inherit pkgs shell;
}
