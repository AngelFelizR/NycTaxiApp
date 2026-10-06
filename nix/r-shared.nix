# The one package needed to read the shared configuration in shared/*.yaml
# (curves, brand palette) from both frontends. Deliberately its own module so
# the intent is visible: this is not part of the Shiny stack, it is the price
# of keeping one visual spec between app/ and share/ (see
# docs/decisions/0003-shared-visual-config.md).
#
# `pkgs` is a parameter: see nix/r-shiny.nix. The root default.nix picks this
# up automatically (r-*.nix), and r-app.nix / share/default.dev.nix import it.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "r-shared-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        # shared/load.R parses shared/curves.yaml and shared/brand.yaml.
        yaml;
    };
  }
