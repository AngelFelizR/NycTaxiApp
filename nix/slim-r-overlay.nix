# Makes the pin's `R` the slim one (nix/r-slim.nix), so that EVERYTHING built
# from that pin -- including nixpkgs' own rPackages -- references the same
# single R.
#
# Why this file has to exist, and why it is not inside r-slim.nix: the strip
# used to be applied only by nix/system.nix and nix/system-runtime.nix, which
# put a slim R in /opt/system. That is only half the job. The compiled R
# packages carry an RPATH to `pkgs.R` -- verified in the shipped images: every
# .so of /opt/r (glue, cli, Rcpp, ggiraph, httpuv, qs2, ...) pointed at a
# SECOND, unstripped R, and that R's Makeconf dragged openjdk (573 MB) and
# glib-dev (-> python3, 144 MB) right back into the image. The system layer
# measured 585 MB; the images never saw that number.
#
# `pkgs` passed into r-slim.nix must be `prev`, the set WITHOUT this overlay:
# r-slim.nix reads `pkgs.R`, so an already-slimmed set would recurse. That is
# also why this is expressed as an overlay on the import rather than as an
# attribute inside r-slim.nix.
final: prev: {
  R = import ./r-slim.nix { pkgs = prev; };

  # Python in the UI image does NOT come from R -- it comes from gdal, which
  # sf and terra need for libgdal.so (67 MB, legitimately) but which also
  # ships its Python module and ~20 CLI scripts whose shebangs point at numpy,
  # and numpy at python3 (measured: 199 MB in the UI image). Nothing in this
  # repository runs those scripts; sf and terra link libgdal.so directly.
  #
  # gdal does NOT propagate python (measured: no python in buildInputs,
  # propagatedBuildInputs or propagatedNativeBuildInputs, and no
  # nix-support/propagated-build-inputs) -- the reference lives only in the
  # files, which is why deleting them is enough and why this does not need
  # remove-references-to.
  #
  # Two traps, both measured:
  #   - half the scripts are DOTfiles (`.gdal_edit-wrapped`, and the glob
  #     `$out/bin/*` does not match dotfiles);
  #   - the other half (`gdal_merge`, `gdal2xyz`, ...) are BASH wrappers whose
  #     first line is `#!/.../bash` and which carry the numpy store path in a
  #     PATH assignment, so filtering on a `#!...python` shebang finds neither.
  # So the filter is the store path itself, and `find` rather than a glob.
  gdal = prev.gdal.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      chmod -R u+w $out
      rm -rf "$out"/lib/python3*
      if [ -d "$out/bin" ]; then
        find "$out/bin" -maxdepth 1 -type f -print0 2>/dev/null \
          | xargs -0 grep -lZ -E '/nix/store/[a-z0-9]{32}-[^/[:space:]]*(python|numpy)' 2>/dev/null \
          | xargs -0 -r rm -f
      fi
    '';
  });
}
