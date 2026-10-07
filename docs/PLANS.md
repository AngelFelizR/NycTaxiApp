# Plans

A living record of the roadmap, so a lost session does not lose the work that
is still to come. It is **not** a decision record: decisions live in
[`docs/decisions/`](decisions/README.md) (ADRs), divergences from the master
document in [`CHANGELOG.md`](../CHANGELOG.md), and how to work in this repo in
[`AGENTS.md`](../AGENTS.md). This file only says *what is next and why*.

Update it when a plan changes or lands. Nothing here is a commitment to a
date.

---

## Status

### Done

- **Phases 0–6**: contracts, API, UI (Setup / Trips / Results / feedback),
  the public `share/` service, `shared/` visual config, privacy notice.
- **Phase 7**: `docker-compose.prod.yml`, Nginx edge, ShinyProxy, the four
  infra scripts, three multi-stage Dockerfiles, the CI workflow, and the three
  images built and smoke-tested (`infra/scripts/smoke-stack.sh`).
- **R0–R5** (post-audit remediation): decision-record taxonomy + ADR template;
  production-stack smoke test and the six bugs it found; the §10 checks and
  the swallowed-async-error bug; container hardening (ADR-004); the data
  release tooling and `POST /render-card` (ADR-005); `health_check.sh`, the
  backup watch in `disk_check.sh`, and §11's structured request log.
- **R6.1**: response-body conformance with the contract (ADR-0006) and the
  four real defects its first run found.
- **CI**: five jobs run on a PR. Four are green (`test-contract`, `test-api`,
  `test-share`, `test-integration`), `build-share` produces an image, and
  `test-shiny` is the last red one (see below).

### In progress

- **R6.2 — the CI run itself.** Diagnostics are in place: `ci_report.sh`
  turns a test log into public GitHub annotations, and every test job tees its
  output.
  - `test-shiny` fails waiting for `#setup-validate` **after** a
    `window.location.reload()`. The `DIAG` line proves the data is fine in CI
    (`app_data_dir` exists, `zones=263`, mock API answering) — the problem is
    the reload itself. Visible difference: CI drives `/usr/bin/google-chrome`
    while the shell provides Nix's `chromium`.
  - Nix build flakes (`compilation failed for package 'brotli'`) took down
    `test-integration` and `test-share` once each; both jobs now retry
    building their shell as a separate step, never the tests.

---

## Plan A — convert `api/` and `app/` into real R packages (R6.3)

**Why.** `covr::package_coverage()` needs a `NAMESPACE` *and* all code at the
top level of `R/`: R **ignores subdirectories** of `R/` (verified — `load_all`
loaded only `api/R/utils.R` out of 30 files). §10 asks for ~60 % coverage
globally and 100 % on `sensitivity`, `rate_limit`, `migrations`, `simulate`,
`internal_auth`, `client_ip` and `outcome`, and none of it can be measured
today.

**Second why.** The deployment images should not carry development packages.

### Decisions fixed (2026-10-07)

| | |
|---|---|
| Layout | `R/` flat in both packages, keeping the layer in the **file name**: `db_`, `ml_`, `endpoint_`, `middleware_`, `data_` for the API; `mod_*` unchanged for the app |
| Loading | **installed in production** (`R CMD INSTALL` in the Dockerfile, `library()` at boot), **`pkgload::load_all()` in dev and tests** |
| `NAMESPACE` | `exportPattern("^[^\\.]")` only — no `import()`; the entry points attach dependencies exactly as they do today |
| Dev-only packages | out of the runtime sets: `shinytest2` moves from `nix/r-shiny.nix` to `nix/test-tools.nix` |
| Stubs | the `assign(..., globalenv())` overrides stop reaching the code once it lives in a namespace → `local_mocked_bindings(..., .package = ...)` |

### Phase 1 — `api/` — **done** (commit `f12da8b`)

1. ~~**`R CMD INSTALL` into a temp library, first**~~ — passed before the move., before touching anything.
   This has never been tried and it is the load-bearing step; if it fails, the
   plan changes here.
2. Flatten `api/R/` (30 files): `db_*`, `ml_*`, `endpoint_*`,
   `middleware_*`, `data_trips.R`, `ml_step_join_geospatial_features.R`,
   `utils.R`. Resolves the two collisions (`predict.R`, `sensitivity.R`).
3. Add `api/NAMESPACE`.
4. `api/plumber.R`: the 30 `source()` calls become
   `library(taxiapi)` when installed, else `pkgload::load_all()`. `load_dotenv`
   moves after the load.
5. `api/tests/testthat/helper-load.R`: same, with an `R_COVR` branch — under
   `covr` the installed (instrumented) copy must win, never `load_all`.
6. `tools/build_reference_distribution.R`: its 6-file list → `load_all`.
7. Stubs → `local_mocked_bindings` in `helper-sim.R`, `test-rate-limit.R`,
   `test-simulate.R`, `test-sensitivity.R`, `test-endpoints.R`,
   `test-contract-conformance.R`.
8. Path references: `integration/tests/testthat/test-share-email-push.R`,
   `integration/tests/testthat/test-router-auth.R`, `AGENTS.md`.
9. `api/default.dev.nix`: + `pkgload`, + `covr`. `nix/r-api.nix` unchanged.
10. `api/Dockerfile`: `RUN R CMD INSTALL --library=/opt/r-lib /app/api`
    before `USER`, `R_LIBS_SITE=/opt/r-lib:/opt/r/library`.
11. **ADR-0007** in the same commit. Alternatives to record: keep
    `covr::file_coverage()` (verified: it sources into a fresh environment, so
    the `globalenv()` stubs stop applying), `covr::environment_coverage()`
    (ran the whole suite green but returned an empty coverage object), and
    doing nothing.

### Phase 2 — `app/` — **done** (commit that ships it)

Same shape, plus:

- Flatten `app/R/modules/` (9 files, no name collisions) into `app/R/`.
  **This diverges from §6.2 of the master document**, which draws
  `app/R/modules/` — annotate in `CHANGELOG.md`, never edit the document.
- Update `app/app.R`, `app/tests/testthat/helper-load.R`,
  `test-session-isolation.R`, `test-privacy.R`, `AGENTS.md`, ADR-0003.
- `app/Dockerfile`: same `R CMD INSTALL`.
- Move `shinytest2` from `nix/r-shiny.nix` to `nix/test-tools.nix` so the UI
  image stops carrying it (`nix/r-dev.nix` is already excluded via
  `withDev = false`).
- The app package name is already `taxiapp`.

### Phase 3 — coverage (§10)

1. `api/tests/coverage.R` driving `covr::package_coverage()`. *(not started)*
2. A CI step in `test-api` that writes the number to the step summary.
3. **Measure before enforcing.** The first run only reports; the §10
   thresholds (60 % global, 100 % on the seven critical files) are set once
   the real number is known.

### Verification, in order *(steps 1-3 done; 4-5 pending)*

1. `R CMD INSTALL` clean for `api/`, then `app/`.
2. Suites: `api/`, `share/`, `app/`, `integration/` — all green.
3. `Rscript api/plumber.R` and `Rscript app/app.R` boot **in dev** via
   `load_all`.
4. Build both images and check `/health` 200 / `GET /` 200 — the only proof
   that the `library()` branch works.
5. `actionlint`; Spectral unchanged.

### Risks

- `R CMD INSTALL` has not been tried (step 1 above).
- Byte-compiling at install time runs top-level code once; verified there is
  essentially none, but the suites are the real check.
- `load_all` sorts files alphabetically instead of following the explicit
  order in `plumber.R`; no top-level ordering dependency was found.

---

## Plan B — R7: image size

`nix/system-runtime.nix` without `nix`, the toolchain or `glibc-locales` for
the runtime images: **ADR-0008**, roughly −2 GB per image (openjdk 572 MB,
source 482 MB, gfortran 338 MB, gcc 283 MB, locales 222 MB, python3 143 MB).
Then rebuild the three images and re-run the smoke stack.

---

## Plan C — `GET /state` made replica-agnostic

Specification given directly; no service redesign, no heartbeat.

- **`api/migrations/002_setup_progress.sql`**: `setup_progress SMALLINT
  CHECK (0..99)` on `experiments`. The timeout stays a function of
  `created_at`, never of a heartbeat.
- The forked child publishes every **5 steps** with
  `UPDATE ... SET setup_progress = $1 WHERE id = $2 AND status = 'setup'` —
  the guard makes a stale child harmless: it can no longer overwrite a day
  that has moved on.
- **`GET /state` reads only Postgres**, with `SELECT ... FOR UPDATE` (or
  `FOR SHARE`) so the row cannot change between read and response.
- **`traj_jobs` stops being the source of truth** (option b): only used to
  detect zombies.
- **5 tests + ADR** documenting it.
- **Do not touch** `contract/openapi.yaml` and do not change the fork.
- `AGENTS.md` + `CHANGELOG.md` updated.

## Plan D — remove the PNG byte cache from Redis

- `share/R/cache.R` keeps `sensitivity`/rate-limit/`share:views`; drops
  `png_cache_get`/`png_cache_put`.
- `share/R/routes.R` renders on every request; **`Cache-Control` and the
  Cloudflare rule stay exactly as they are** (that is the outer layer).
- `/metrics`: `png_cache_hits`/`png_cache_misses` out, `png_renders_total`
  in → **`contract/openapi.yaml` must change** (and Spectral re-run).
- Tests updated; `share:views`, bots and `/health` untouched.
- **ADR superseding part of ADR-009**, plus `CHANGELOG.md` (§7.1 goes from
  three layers to two; §11 loses two metrics), `AGENTS.md` and the runbook.

---

## Blocked — outside this repository

Everything is in [`docs/operations/first-deploy.md`](operations/first-deploy.md):
GitHub secrets for the deploy, SMTP credentials + SPF/DKIM/DMARC, the
Cloudflare cache rule and DNS, UptimeRobot, the VM swap. Plus two gaps in the
data release: `v0.0.1-data` publishes no `SHA256SUMS`, and it has no
`ReferenceDistribution.qs2`.
