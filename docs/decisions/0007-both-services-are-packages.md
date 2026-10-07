# 0007. Both services are R packages: flat `R/`, installed in production, `load_all` in development

- Status: Accepted
- Date: 2026-10-07
- Phase: 10 (§10 — coverage), §1.1 (image contents), §6.2 (the app's layout)
- Relates to: ADR-0006 (response conformance — the precedent that a check is
  worth having), ADR-0004 (container hardening — `R CMD INSTALL` runs before
  `USER`), master document §10 and §6.2

## Context

**Section 10 asks for numbers nobody can produce**: ~60 % coverage globally
and 100 % on `sensitivity.R`, `rate_limit.R`, `migrations.R`, `simulate.R`,
`internal_auth.R`, `client_ip.R` and `outcome.R`. `covr` is the only R tool
that produces them, and it has two requirements this repository did not meet:

1. a `NAMESPACE` — neither `api/` nor `app/` had one, and `DESCRIPTION` said
   "not an installable package";
2. all the code at the **top level of `R/`** — R ignores subdirectories of
   `R/`. Measured before touching anything: `load_all()` on `api/` loaded
   `R/utils.R` (17 functions) and **none** of the other 29 files, which live
   under `R/db/`, `R/ml/`, `R/endpoints/`, `R/middleware/` and `R/data/`.

The second requirement forces a restructure, which is why this is a decision
and not a chore.

A second pressure pointed the same way: both images should carry only what
they run. `nix/r-shiny.nix` put `shinytest2` in the UI's runtime set, so the
production image shipped a test browser driver; `plumber2` was already
excluded from it by `withDev = false`, but the principle was not applied
consistently.

## Decision

**`api/` and `app/` are R packages. Development loads them with
`pkgload::load_all()`; the images install them with `R CMD INSTALL` and boot
with `library()`.**

- **`R/` is flat in both**, and the layer the old directories carried moves
  into the file name: `db_pool.R`, `ml_predict.R`, `endpoint_predict.R`,
  `middleware_client_ip.R`, `data_trips.R`, `ml_step_join_geospatial_features.R`
  for the API; `mod_*` unchanged for the app. Read as one directory grouped by
  prefix, which is what the tree used to say.
- **`NAMESPACE` exports everything and declares the S3 methods**, nothing
  else: `exportPattern("^[^\\.]")` plus the four `S3method()` entries for
  `prep`/`bake`/`required_pkgs`/`print` on `step_join_geospatial_features`.
  No `import()` — the entry points attach dependencies exactly as they did
  when the code was sourced, and hand-writing twenty imports without roxygen
  buys a `R CMD check` this repository does not run, at the cost of possible
  name conflicts.
- **One loader, selected by what is available.** `plumber.R` does
  `library(taxiapi)` when an installed copy exists and `load_all()` otherwise,
  so a development shell needs no install step and an image needs no pkgload.
- **`helper-load.R` branches on `R_COVR`.** Under coverage, `covr` has
  installed an instrumented copy into a temporary library and `load_all()`
  would overwrite it with uninstrumented source — measuring nothing.
- **Dev-only packages leave the runtime sets**: `shinytest2` moves from
  `nix/r-shiny.nix` to `nix/test-tools.nix`, which is already the home of
  `chromium` and is present only in development shells.

## Alternatives

- **`covr::file_coverage()` over the existing tree.** Rejected after trying
  it: it sources into `new.env(parent = ...)`, so the tests' `assign(…,
  globalenv())` stubs are shadowed by the copies in that environment and stop
  applying. It reported 2 real failures out of 38 in its first run — failures
  of the harness, not of the code.
- **`covr::environment_coverage(globalenv(), …)`** — the public API for
  instrumenting an environment that already holds the code. Attractive because
  it needs no restructure: it ran the **entire suite green** (582
  expectations) and still returned an empty coverage object. The cause was not
  pinned down, and a harness that passes while measuring nothing is worse than
  one that fails honestly.
- **`pkgload::load_all()` everywhere, including production.** Rejected in
  favour of installing: pkgload (and its ~10 dependencies) would live in the
  image, `R CMD check`-style behaviour would differ from what ships, and §1.1
  is about not carrying what is not used.
- **Install in production, keep sourcing in development.** Rejected: two
  loading mechanisms for the same files, when `load_all()` is the standard
  development path and needs no install.
- **Hand-write `import()` for every dependency.** Rejected: without roxygen
  there is no generator, twenty `importFrom` lines rot silently, and a
  conflict between `recipes`, `themis` and `embed` would fail at load time in
  production for no benefit — the entry points already attach what the code
  uses.
- **Do nothing**, and report §10's coverage as unmeasurable. Rejected: §10
  states the target as a requirement, and three of the four paths were proved
  unworkable rather than merely unattractive.

## Consequences

- **Two bugs the conversion exposed**, both invisible while the code lived in
  `globalenv()`:
  1. **`data.table::cedta()`** silently downgrades `x[i, on = …]` to
     `[.data.frame` when the calling package is not registered as
     data.table-aware, which then dies with "invalid subscript type 'list'".
     The package sets `.datatable.aware <- TRUE` (kept out of
     `exportPattern` by its leading dot). Only one test caught it.
  2. **S3 methods are not found by being merely attached**; they are found
     because a package declares them. `prep.step_join_geospatial_features`
     worked while it sat in `globalenv()` and stopped the moment it moved.
- **Test stubs change shape.** `assign(…, globalenv())` cannot reach a binding
  in a namespace (and a namespace locks its bindings), so every override is now
  `local_mocked_bindings(…, .package = "taxiapi")`. Nesting two of them in
  *different* frames restores out of order and the inner restore fails with
  "cannot change value of locked binding" — `test-simulate.R` had to be
  restructured so its two mocks are siblings instead. Same-frame repeats are
  fine (LIFO).
- **`R CMD INSTALL` now runs in both Dockerfiles**, before `USER`, into a
  writable library the runtime `R_LIBS_SITE` points at. Any change to `R/`
  re-runs it; it is pure R and takes seconds.
- **`pkgload` and `covr` live only in dev shells** (`api/default.dev.nix`,
  `nix/r-dev.nix`) — never in `nix/r-api.nix` or `nix/r-shiny.nix`, which are
  image layers.
- **File order is now alphabetical**, where `plumber.R` used to source a
  hand-written list. No top-level statement in the API depends on another
  file being loaded first (verified), but the suites are the real check.
- **§6.2 of the master document draws `app/R/modules/`**, and the app's
  `R/` must be flat for the same reason. **Annotated in `CHANGELOG.md`**; the
  document is not edited.
- **Follow-ups:** `covr` is wired but §10's thresholds are not enforced until
  a first number exists; `R CMD check` is still not part of the gate.
