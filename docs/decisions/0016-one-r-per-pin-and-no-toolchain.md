# 0016. The images ship one R, and the toolchain really is gone from it

- Status: Accepted
- Date: 2026-10-10
- Phase: 7 (§1.1 image size)
- Relates to: ADR-0008 (why a patched R looked necessary), ADR-0011 (the
  strip itself, and the claim this corrects), ADR-0015 (the registry the
  images come from)

## Context

ADR-0011 stripped the toolchain out of R's configuration files and measured
the result on `nix/system.nix`: closure 2608 MB → 585 MB, `openjdk`,
`gcc-wrapper`, `gfortran-wrapper`, `python3` and `glib-dev` all gone. That
measurement was correct, and the conclusion drawn from it was not. Its
Decision ends *"so there is exactly one R per pin"*.

Opening the shipped images settles it. The UI image contained **two**
derivations of R 4.6.1:

| Store path | `etc/javaconf` | Who uses it |
|---|---|---|
| `8hmihcl…-R-4.6.1` | absent (stripped) | `/opt/system/lib/R` — the R that runs |
| `z6bf2rm…-R-4.6.1` | **present** | the RPATH of every compiled `.so` in `/opt/r` |

`r-slim.nix` was applied by `nix/system.nix` and `nix/system-runtime.nix`,
which put a slim R in `/opt/system`. It was never applied to `pkgs.R`, which
is what nixpkgs' `rPackages` are built against — so 63 of the UI's 106
packages (and 12 of the API's) pointed at a second, unstripped R, and that
R's `Makeconf` dragged the toolchain straight back in. Measured in the image,
still present:

```
openjdk 572 MB   gcc 305 MB   gfortran 353 MB   python3 199 MB   ≈ 1.4 GB
```

A second, independent path put Python in the UI: `sf` and `terra` link
`libgdal.so` (67 MB, legitimate), and `gdal` also ships its Python module and
about twenty CLI scripts whose shebangs and PATH entries name `numpy`, which
names `python3`. Nothing in this repository runs those scripts.

## Decision

**The pin slims its own R, so there is genuinely one R per pin, and the
compiled packages reference it.** `nix/pkgs.nix`, `pkgs-api.nix` and
`pkgs-app.nix` apply `nix/slim-r-overlay.nix`, which sets
`R = import ./r-slim.nix { pkgs = prev; }`. `nix/system.nix` and
`nix/system-runtime.nix` now just `inherit (pkgs) R` — building another slim R
there would be the same bug in reverse.

Three changes inside `nix/r-slim.nix`, each with a different treatment
because the references are different in kind:

- **`gcc-wrapper` is rewritten to the bare command.** `CC` becomes `cc`,
  `CXX` becomes `c++`. The store path disappears while the command still
  resolves inside a Nix build, where stdenv puts `cc` on PATH. With the old
  blanked form (`/nix/store/eeee…-gcc-wrapper/bin/cc`) `R CMD SHLIB` dies with
  "No such file or directory"; with the bare name the same command produces a
  16 KB `.so`. `gcc` (unwrapped, 284 MB) goes with it, its `-L` entries
  removed from `FLIBS`, `ldpaths` and libtool's `sys_lib_search_path_spec` —
  the pattern requires `/` right after the version digits, so
  `…-gcc-16.2.0-lib/lib` does not match and the `-lib` output (11 MB, holding
  `libgcc_s.so`) survives.
- **`openjdk`, `glib-dev`, `cairo-dev`, `pango-dev` and `graphviz` are
  blanked**, as ADR-0011 did. `etc/javaconf` is deleted.
- **`gfortran` is kept, at 339 MB.** See Alternatives: `FC` and `F77` keep
  the full store path, so gfortran stays in every image that contains R.

And in the overlay, **`gdal` loses its Python half**: `lib/python3*` is
deleted and every file in `bin/` whose contents name a python or numpy store
path is deleted. `libgdal.so` is untouched, so `sf` and `terra` are unaffected.

Measured afterwards on the rebuilt sets: `r-share`, `r-shared`, `r-app`
(106 packages, incl. `sf`, `terra`, `classInt`) and `r-api` (169 packages,
incl. `Matrix`, `RcppEigen`, `RSpectra`, `irlba`) all build; the new gdal's
closure contains **zero** python paths.

## Alternatives

- **Leave `pkgs.R` alone and strip only the system layer** — that is what
  ADR-0011 did, and it is what this ADR corrects. The images never saw the
  585 MB figure; the packages handed the toolchain back.
- **Build the R packages against the fully stripped R.** Rejected and
  measured: `Makeconf`'s `CC` becomes `/nix/store/eeee…/bin/cc`, which does
  not exist, so every package with a `src/` directory fails to compile. The
  rewrite to a bare name is what makes the same strip survivable.
- **Supply `gfortran` to the packages, so it can go too.** Three mechanisms
  were tried and measured, all rejected:
  - `propagatedNativeBuildInputs = [ gfortran ]` on R — does not reach the
    packages; `rPackages.KernSmooth` still fails with "gfortran: command not
    found" while `rPackages.glue` (pure C) builds.
  - a list of the Fortran packages (`classInt`, `irlba`, `KernSmooth`,
    `Matrix`, `RcppEigen`, `RSpectra`, `sitmo`, taken by scanning every
    shipped `.so` for `libgfortran`) overridden in the overlay — fixes only
    direct references, so `classInt` still built its own unpatched
    `KernSmooth` and failed. Inside nixpkgs the packages resolve each other
    through r-modules' internal `self`, which an outer overlay cannot reach.
  - `rPackages.overrideScope` — does not exist in this nixpkgs: `rPackages`
    is `recurseIntoAttrsWith (callPackage …)`, not a scope.
  Paying 339 MB is cheaper than owning a patched nixpkgs.
- **Delete `gdal`'s Python by blanking with `remove-references-to`.** Rejected
  in favour of deletion: the files are useless here, deleting saves their
  bytes as well, and a blanked `#!` line leaves a script that is broken
  rather than absent.
- **Filter gdal's scripts on a `#!…python` shebang.** Rejected, measured:
  half of them are dotfiles (`$out/bin/*` does not match dotfiles) and the
  other half are bash wrappers carrying the numpy path in a PATH assignment.
  The filter is the store path itself, via `find`.
- **Do nothing.** Rejected: §1.1 limits RAM, not image size, but 1.4 GB of
  JDK and compilers in a runtime image is a standing cost on every push and a
  standing question at the next audit — which is exactly what ADR-0011 set
  out to answer.

## Consequences

- **~1.4 GB per image is recovered** once the three are rebuilt: openjdk 572,
  gcc 284, python3 + numpy 199, and the gdal Python half. gfortran (353) and
  the `-lib` outputs (25) stay.
- **Changing the pins invalidates everything built from them.** The first
  rebuild compiles R and then every R package: measured locally, 25 min for
  `r-share`, 19 for `r-app`, 42 for `r-api`, 46 for gdal. The public
  `rstats-on-nix` cache cannot help, because no package there was built
  against this R.
- **`R CMD INSTALL` no longer compiles outside a Nix build** (ADR-0011's
  property, kept): there is no compiler on PATH. Inside one it does, which is
  what nixpkgs' own packages need. The two `.R` packages of this repository
  are pure R and `.Rprofile` refuses `install.packages()` anyway.
- **The development image is not in scope.** It imports the same pins, so its
  R is slim too, but it was not rebuilt or re-measured as part of this
  change — its size is a follow-up, and ADR-0011's numbers for it still
  describe the system layer only.
- **Divergences:** none with the master document. §1.1 limits RAM; nothing in
  it names a package set or a store path.

- **Follow-ups:** rebuild the three deployment images and record the before
  and after; add the development image to the same measurement.
