# 0008. The images drop `nix` from their system layer — and the other 1.34 GB cannot be reached that way

- Status: Accepted
- Date: 2026-10-07
- Phase: 7 (§1.1 image size, §8.6 push time)
- Relates to: ADR-0004 (container hardening — the layers this sits in),
  master document §1.1 (which limits RAM, not image size)

## Context

AGENTS carried a follow-up that read: *separar un `nix/system-runtime.nix`
(sin `nix`, sin toolchain) para las imágenes bajaría cada una ~2 GB*. The
number was never measured, and measuring it first changes the plan:

```
nix/system.nix closure:        2608 MB  (284 paths, 10 declared packages)
  of which `nix` itself:        206 MB  (63 paths)
  of which `R` references:     2364 MB  ← everything else
```

`nix/system.nix` declares `glibcLocales, nix, R, which, curl, fontconfig,
dejavu_fonts, freefont_ttf`. It does not declare a toolchain. The toolchain is
in **`R`'s own output**: `nix why-depends` shows `R-4.6.1` referencing
`openjdk` (573 MB), `gfortran` (339), `gcc` (284) and `python3` (144) — they
are `R`'s `buildInputs`, which its derivation writes into files it ships
(`Makeconf`, `R CMD config`). Splitting an expression cannot remove them.

So the plan as written buys 206 MB, not 2 GB — and the remaining 1.34 GB is a
different change with a different risk profile. That difference is what this
ADR records.

## Decision

**The three deployment images build `nix/system-runtime.nix`, which is
`nix/system.nix` minus `nix`; development shells keep `system.nix`.**

Measured on the API pin: the closure goes **2608 → 2364 MB (−244 MB)** and
`nix` no longer appears in it. The *images* shrank by less than that —
share 4.3 → 4.23 GB, api 4.9 → 4.83 GB, shiny 5.32 → 5.22 GB (the shiny delta
also carries `shinytest2` leaving the set) — because summing `du` once per
store path counts the files hard-linked into paths that stay once per path;
244 MB is an upper bound, ~70 MB is what the layer actually lost. Both numbers
are recorded here because the first one is the one that gets quoted.

The two files differ by one package **on purpose**. A shell is where you run
`nix`; an image never does — it is built `FROM nixos/nix`, so the CLI is
already present and ours was a duplicate. Crucially there is no *behavioural*
difference between the two at runtime, only an unused binary, which is what
makes a test/prod divergence acceptable here. Everything the images do
assert — `FONTCONFIG_FILE`, `LOCALE_ARCHIVE`, `curl` on `/opt/system/bin` —
is unchanged.

## Alternatives

- **Strip `openjdk`, `gcc`, `gfortran` and `python3` out of R's closure with
  `removeReferencesTo`** (the remaining ~1.34 GB). Rejected for now because it
  means owning a custom R derivation rather than calling `pkgs.R`: the
  references are written by R's own build, so the tool is a post-build
  rewrite of a package we would have to revalidate — `R CMD INSTALL` (which
  the images now run) and R's startup both have to be retested, and `gcc`
  removal silently breaks the first package with compiled code that anyone
  adds. §1.1 limits RAM (256 MB / 1.5 GB) and says nothing about image size,
  so nothing here requires the risk. **The only path to those bytes, and a
  separate project.**
- **Drop the fonts from the API image too** (fontconfig 54 MB + dejavu 11 +
  freefont 11 ≈ 76 MB). Rejected: development shells would keep fonts while
  the image lost them, so a font-dependent failure could only appear in
  production, for 2 % more. `share/` renders PNGs with ragg and cannot lose
  them; `api/` renders nothing, but "renders nothing today" is not worth an
  asymmetry no test exercises.
- **Do nothing.** Rejected: the change is one line per Dockerfile, it is
  measured, and image size is what the GHCR push time is made of.

## Consequences

- **The three images have to be rebuilt and re-smoked** — the closure change
  is not observable any other way. The smoke stack is the check that
  `/opt/system` still resolves and that the healthcheck still finds `curl`.
- **AGENTS' "Peso de las imágenes" section is corrected**: the toolchain does
  not come from `system.nix`, and the honest remainder is "R's own closure",
  with this ADR as the record of why it is left alone.
- **`nix/system.nix` stays the development layer** and keeps `nix`, so
  `default.nix`, `api|app|share/default.dev.nix` and `default.prod.nix` are
  untouched.
- **Follow-up (optional, measured):** fonts in the API image (~76 MB) if the
  test/prod asymmetry is ever accepted, and R's toolchain (1.34 GB) if push
  time ever justifies owning a patched R.
