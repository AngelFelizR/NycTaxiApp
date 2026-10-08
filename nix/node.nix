# Node, for the UI's end-to-end tests (section 10, phase 8).
#
# Deliberately its own file and not a line in nix/system.nix: system.nix is
# imported by every dev shell AND by the three deployment images, so adding
# anything to it invalidates all of them. This one is only imported by the
# layer at the end of the root Dockerfile, where nothing follows it.
#
# Cypress itself is NOT installed from pkgs.cypress: the pin marks
# cypress-15.19.0 as insecure (nix wants `permittedInsecurePackages`), and
# granting that means editing nix/pkgs.nix -- which invalidates every layer in
# the image. It is installed with npm instead, which is how Cypress is meant
# to be installed anyway. Recorded in ADR-0011.
{ pkgs ? import ./pkgs.nix }:
  pkgs.buildEnv {
    name = "node-packages";
    paths = [ pkgs.nodejs ];
  }
