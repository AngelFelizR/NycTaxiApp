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
# WHAT IS DONE TO WHICH REFERENCE, AND WHY THEY ARE NOT ALL TREATED THE SAME
#
#   openjdk, glib-dev, cairo-dev, pango-dev, graphviz
#       blanked with remove-references-to. Nothing needs them at run time and
#       nothing can need them at build time: glib-dev/cairo-dev/pango-dev are
#       the path that used to drag python3 into the closure, and openjdk is the
#       single largest item of all (573 MB). The same tool removes their
#       references from the four text files listed below, and etc/javaconf is
#       deleted outright.
#
#   gcc-wrapper
#       REWRITTEN to the bare command name, not blanked. `CC` becomes `cc`,
#       `CXX` becomes `c++`. That is what keeps `R CMD INSTALL` working inside
#       a Nix build -- stdenv puts `cc` on PATH -- while the reference to the
#       store path disappears. Verified: with the blanked form
#       (`/nix/store/eeee...-gcc-wrapper/bin/cc`) `R CMD SHLIB` dies with
#       "No such file or directory"; with the bare name the same command
#       produces a 16 KB .so. gcc (the unwrapped output, 284 MB) goes with it.
#
#   gfortran
#       deliberately NOT rewritten: `FC` and `F77` keep the full store path,
#       so gfortran (339 MB) stays in every image that contains R. Not for
#       want of trying. nixpkgs' builder is
#       `buildRPackage = pkgs.callPackage ./generic-builder.nix { inherit R; }`
#       and generic-builder.nix puts `[ R ]` in nativeBuildInputs but declares
#       no gfortran, so the only reason `FC = gfortran` ever resolved was that
#       the store path in Makeconf put gfortran in R's closure -- and hence in
#       every sandbox that depended on R. Rewriting FC to the bare name was
#       measured to break every Fortran package (`rPackages.KernSmooth` fails
#       with "gfortran: command not found" while `rPackages.glue`, pure C,
#       builds). Three ways of re-supplying it were tried and measured:
#       `propagatedNativeBuildInputs` on R does not reach the packages; a list
#       of Fortran packages in an overlay only fixes direct references, so
#       `classInt` still built its own unpatched `KernSmooth` and failed; and
#       `rPackages.overrideScope` does not exist in this nixpkgs at all
#       (`rPackages` is `recurseIntoAttrsWith (callPackage ...)`, not a scope).
#       Paying 339 MB is cheaper than owning a patched nixpkgs.
#
#   openjdk, glib-dev, cairo-dev, pango-dev, graphviz
#       blanked with remove-references-to. Nothing needs them at run time and
#       nothing can need them at build time: glib-dev/cairo-dev/pango-dev are
#       the path that used to drag python3 into the closure, and openjdk is the
#       single largest item of all (573 MB). The same tool removes their
#       references from the four text files listed below, and etc/javaconf is
#       deleted outright.
#
# The consequence to know about: `R CMD INSTALL` can no longer compile outside
# a Nix build, because there is no compiler on PATH. That is acceptable here
# and is recorded in ADR-0011/ADR-0016: our packages are pure R and
# `.Rprofile` refuses install.packages() anyway. INSIDE a Nix build it still
# compiles, which is what nixpkgs' own rPackages need.
#
# `remove-references-to -t <store-path> <file>...` rewrites the 32-character
# store id inside exactly the files named, so no shared object or binary is
# rewritten by accident.
#
# `pkgs` is REQUIRED and must be the unoverlaid set: this reads `pkgs.R`, so
# an already-slimmed set would recurse. nix/slim-r-overlay.nix is the only
# caller that matters, and it passes `prev`.
{ pkgs }:
  # overrideAttrs, not overrideDerivation: the latter was removed from
  # nixpkgs years ago ("attribute 'overrideDerivation' missing"). This
  # rebuilds R with the tool in its build inputs and the strip step after
  # the fixup, so the output is a normal R with four files edited -- which is
  # also why it costs a full R compile the first time.
  #
  # `pkgs` must be the UNOVERLAID set (see slim-r-overlay.nix): this reads
  # `pkgs.R`, so passing an already-slimmed set would recurse.
  pkgs.R.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.removeReferencesTo ];
    postFixup = (old.postFixup or "") + ''
      chmod -R u+w $out
      makeconf=$out/lib/R/etc/Makeconf
      ldpaths=$out/lib/R/etc/ldpaths
      libtool=$out/lib/R/bin/libtool

      # 1. The gcc wrapper becomes a bare command. [^/[:space:]"] stops at the
      #    end of the store name; [^[:space:]"]+ takes the tool name and stops
      #    at the space before any flags (`CXX = .../bin/c++ -std=gnu++20`) or
      #    at the closing quote libtool puts around its assignments. The
      #    gfortran wrapper is NOT here -- see the note at the top.
      for f in "$makeconf" "$ldpaths" "$libtool"; do
        sed -E -i \
          -e 's|/nix/store/[a-z0-9]{32}-gcc-wrapper-[0-9][^/[:space:]"]*/bin/([^[:space:]"]+)|\1|g' \
          "$f"
      done

      # 2. gcc unwrapped only ever appears as an -L search path. The pattern
      #    requires `/` right after the version digits, so
      #    `...-gcc-16.2.0-lib/lib` does NOT match and survives -- which is the
      #    whole point, since libgcc_s.so lives there and R itself links it.
      #    `#` is the sed delimiter because the pattern alternates with `|`.
      sed -E -i \
        -e 's#-L/nix/store/[a-z0-9]{32}-gcc-[0-9]+(\.[0-9]+)*/[^[:space:]"]+##g' \
        "$makeconf"
      sed -E -i \
        -e 's#/nix/store/[a-z0-9]{32}-gcc-[0-9]+(\.[0-9]+)*/[^:[:space:]"]+:?##g' \
        "$ldpaths"
      sed -E -i \
        -e 's#/nix/store/[a-z0-9]{32}-gcc-[0-9]+(\.[0-9]+)*/[^[:space:]"]+##g' \
        "$libtool"

      # 3. Everything that has no runtime job at all is blanked.
      remove-references-to \
        -t ${pkgs.openjdk} \
        -t ${pkgs.glib.dev} \
        -t ${pkgs.cairo.dev} \
        -t ${pkgs.pango.dev} \
        -t ${pkgs.graphviz} \
        "$makeconf" "$ldpaths" "$libtool" \
        $out/lib/R/etc/javaconf
      rm -f $out/lib/R/etc/javaconf
    '';
  })
