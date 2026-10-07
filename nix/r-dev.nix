# Development/testing tools shared by the root shell and the service shells:
# testthat runs every suite and plumber2 runs app/dev/mock_api.R (the flow test
# drives the UI against it). `pkgs` is a parameter: see nix/r-shiny.nix.
#
# NOT here: devtools and roxygen2. Nothing can use them -- app/ is explicitly
# not an installed package (no NAMESPACE, no man/; see AGENTS.md) and api/ has
# its own r-api.nix -- so they only added ~75 MB of closure to every image.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "r-dev-pkgs";
    paths = builtins.attrValues {
      inherit (pkgs.rPackages)
        testthat
        # Background workers: share/tests/testthat/test-routes.R boots the
        # service and a stub of the API in child processes.
        callr
        plumber2
        # ADR-0007: dev loads the packages with pkgload::load_all() instead
        # of the source() lists they used to have. Only dev needs it -- the
        # images install the packages with R CMD INSTALL -- which is why it
        # lives here (excluded from every image via withDev = false) and not
        # in r-api.nix or r-shiny.nix.
        pkgload;
    };
  }
