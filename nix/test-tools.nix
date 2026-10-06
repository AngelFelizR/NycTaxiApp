# Tools that only the TESTS need — never a runtime dependency of any service.
#
# `chromium` (1.3 GB closure) is what chromote drives for the shinytest2 flow
# test. It deliberately lives here instead of nix/system.nix: system.nix is the
# generic layer every deployment image reuses, and none of them needs a browser.
#
# Only the development shells import this file; no image bakes it unless a
# Dockerfile layer says so explicitly.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "test-tools";
    paths = builtins.attrValues {
      inherit (pkgs) chromium;
    };
  }
