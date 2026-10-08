# 0011. The runtime images run R without the toolchain R was built with

- Status: Accepted
- Date: 2026-10-08
- Phase: 7 (§1.1 image size, §8.6 push time)
- Relates to: ADR-0008 (the system layer, and why the obvious version of this
  was rejected), master document §1.1 (which limits RAM, not image size)

## Context

ADR-0008 removed `nix` from the images and recorded, as *rejected*, the
bigger prize: `openjdk` (573 MB), `gfortran` (339), `gcc` (284) and
`python3` (144) travelling inside every closure that contains R. It rejected
it because the obvious reading — "split a Nix expression" — cannot reach
them: they are not in `nix/system.nix`, they are inside **R's own output**.

That rejection rested on an unexamined assumption: that removing them means
*owning a patched R*. It does not. Measuring where the references actually
live settles it:

| Package | Size | Where R mentions it |
|---|---|---|
| `openjdk` | 573 MB | `etc/Makeconf`, `etc/ldpaths`, `etc/javaconf` — **text** |
| `gcc`, `gcc-wrapper` | 284 MB | `etc/Makeconf`, `bin/libtool` — **text**; `gcc-lib` (11 MB) is also in `bin/exec/R`, which is **not** touched |
| `gfortran`, wrapper | 339 MB | `etc/Makeconf`, `etc/ldpaths`, `bin/libtool` — **text**; `gfortran-lib` (14 MB) is in `libR.so` and `stats.so`, untouched |
| `cairo-dev`/`pango-dev` → `glib-dev` → `python3` | 144 MB+ | `etc/Makeconf` — **text** |
| `graphviz` | — | `etc/Makeconf`, `bin/libtool` — **text** |

Every large item is a **string in a configuration file**. The small `-lib`
outputs that R links against dynamically are in binaries and are deliberately
not targeted — `remove-references-to` only rewrites the files it is given.

And nothing here compiles an R package: the two packages that exist are pure
R (both installed and run as proof), and `.Rprofile` refuses
`install.packages()` by design. The toolchain is, for this repository, dead
weight with a security argument attached: a JDK and a compiler in a runtime
image.

## Decision

**`nix/r-slim.nix` wraps `pkgs.R` with `overrideAttrs` and a `postFixup`
that runs `remove-references-to` over the four text files. Both
`nix/system.nix` (shells and the development image) and
`nix/system-runtime.nix` (the three service images) import it, instantiated
with the caller's pin — so there is exactly one R per pin and dev cannot test
a toolchain that production does not run.**

Measured, before and after, same pin:

```
closure of system.nix:  2608 MB / 284 paths  →  585 MB / 146 paths
openjdk, gcc-wrapper, gfortran-wrapper, python3, glib-dev, cairo-dev,
graphviz:                                    present  →  gone
gfortran-…-lib / gcc-…-lib:                  dynamic, kept (14 + 11 MB)
R 4.6.1:                                     starts, locale en_US.UTF-8
R CMD INSTALL (taxiapi, taxiapp):            succeeds
api 607 + share 176 + integration 78 + app 299 + coverage 80.2 %: green
```

`glibc-locales` (223 MB) **stays**: `LANG=en_US.UTF-8` depends on it, and
this repository has already paid for a locale problem (pkgload truncating
`constants.R` at two `§` characters).

## Alternatives

- **Split the expression and drop the toolchain there** — rejected in
  ADR-0008 as impossible: `nix/system.nix` declares ten packages and none of
  them is the problem.
- **Post-processing the store with `remove-references-to` outside Nix**
  (a script run after the build). Rejected: it would not be reproducible from
  the repository, nobody would know it had been run, and the next build would
  silently undo it.
- **Copy R's store path and rewrite it into a new derivation.** Rejected:
  `R_HOME` and the `bin/R` wrapper would still point at the *original* store
  path, so the copy would run the unstripped R and save nothing.
- **Drop `glibc-locales` too** (223 MB more). Rejected: it is a runtime
  dependency of `LANG`, not a build artifact, and the encoding failures it
  would cause are the expensive kind.
- **Drop the fonts and `nix` from the same pass.** `nix` already went
  (ADR-0008); fonts stay because `share/` renders PNGs and the API sets
  `FONTCONFIG_FILE` — removing them from one image but not the others would
  be an asymmetry no test exercises.
- **Do nothing.** Rejected: §1.1 does not require it, but a JDK and a
  compiler in every runtime image are a standing cost on every push and a
  standing question at the next audit.

## Consequences

- **`R CMD INSTALL` can no longer compile C or Fortran.** `Makeconf` points
  at a compiler that is not in the closure. That is acceptable *here* — pure R
  only, and `install.packages()` is blocked — but it is now a property of the
  environment, not of the packages: the first package with a `src/` directory
  needs this file to grow a compiler back, and the failure will be obvious at
  `R CMD INSTALL` time rather than silent.
- **Rebuilding R is the cost of changing this file.** `overrideAttrs` changes
  the derivation, so a edit to `r-slim.nix` recompiles R (~15 min); Nix
  caches it after that.
- **The development image rebuild is not free either.** Changing
  `nix/system.nix` invalidates every layer after it. It was done once, with
  the binary caches already moved to Layer 2 (the fix recorded alongside
  ADR-0010's era), so it was downloads rather than compilations.
- **The image grew for an unrelated reason in the same commit**: layer 11 adds
  Cypress (node + npm + the Electron libraries), which is ADR-0012's business
  and only affects the development image — never a deployment one.
