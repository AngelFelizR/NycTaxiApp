# Shared nixpkgs pin — imported by all other nix files
# Changing this invalidates ALL layers; change it rarely.
import (fetchTarball "https://github.com/rstats-on-nix/nixpkgs/archive/2026-09-28.tar.gz") {}
