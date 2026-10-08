# R with the build toolchain stripped out of its output.
#
# Why this file exists: R's derivation is built WITH openjdk, gcc, gfortran
# and the glib development headers, and it writes absolute store paths to them
# into the files it ships. Nix therefore considers them part of every closure
# that contains R -- 1,340 MB of JDK and compilers travelling inside a runtime
# image (measured: openjdk 573, gfortran 339, gcc 284, glib-dev -> python3
# 144). None of them is needed to RUN R, and nothing in this repository
# compiles an R package: the two packages that exist are pure R, and .Rprofile
# blocks install.packages() by design.
#
# What is stripped, and why only these:
#
#   etc/Makeconf, etc/ldpaths, etc/javaconf, bin/libtool   <- plain text
#
# Those four are where every reference lives, together with cairo-dev,
# pango-dev and graphviz -- all of them text in etc/Makeconf (and libtool), and
# dropping the two -dev ones is what removes python3 (144 MB) from the
# closure, because glib-dev -> python3 and cairo-dev/pango-dev -> glib-dev. The toolchain outputs that R
# links against dynamically are NOT touched -- `gcc-lib` is referenced from
# bin/exec/R, `gfortran-lib` from libR.so and stats.so, `glib` from cairo.so --
# so R keeps every DT_NEEDED it needs to start, and only the compiler paths in
# its configuration files disappear.
#
# The consequence to know about: `R CMD INSTALL` can no longer compile C or
# Fortran, because Makeconf points at a compiler that is not there. That is
# acceptable here and is recorded in ADR-0011: our packages are pure R (both
# were installed and run to prove it) and `.Rprofile` refuses
# install.packages() anyway. If a compiled package ever becomes necessary,
# this expression is what has to grow.
#
# `remove-references-to -t <store-path> <file>...` rewrites the 32-character
# store id inside exactly the files named, so no shared object or binary is
# rewritten by accident.
{ pkgs ? import ./pkgs.nix }:
  # overrideAttrs, not overrideDerivation: the latter was removed from
  # nixpkgs years ago ("attribute 'overrideDerivation' missing"). This
  # rebuilds R with the tool in its build inputs and the strip step after
  # the fixup, so the output is a normal R with four files edited -- which is
  # also why it costs a full R compile the first time.
  pkgs.R.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.removeReferencesTo ];
    postFixup = (old.postFixup or "") + ''
      chmod -R u+w $out
      remove-references-to \
        -t ${pkgs.openjdk} \
        -t ${pkgs.gcc} -t ${pkgs.gcc-unwrapped} \
        -t ${pkgs.gfortran} -t ${pkgs.gfortran.cc} \
        -t ${pkgs.glib.dev} \
        -t ${pkgs.cairo.dev} -t ${pkgs.pango.dev} \
        -t ${pkgs.graphviz} \
        $out/lib/R/etc/Makeconf \
        $out/lib/R/etc/ldpaths \
        $out/lib/R/etc/javaconf \
        $out/lib/R/bin/libtool
      rm -f $out/lib/R/etc/javaconf
    '';
  })
