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
- **CI**: five jobs green on one run (`test-contract`, `test-api` — including
  the coverage step at `COVERAGE_FAIL_UNDER=60` — `test-share`,
  `test-integration`, `test-shiny`), with the three image builds behind them.

### In progress

Nothing in flight. The CI history below explains how it got green:

- Job logs need admin rights to read through the API, so `infra/scripts/ci_report.sh`
  turns a test log into **public annotations** (`GET .../check-runs/{id}/annotations`)
  and every test job tees its output. `DIAG` lines emitted by a test are
  reported first and unconditionally — that is how `test-shiny`'s data
  problem was separated from its reload problem.
- The three Nix build flakes (`compilation failed for package 'brotli'`) were
  fixed by retrying the shell build as its own step, never the tests — and
  then disappeared for good: **the tests now run inside the development image**,
  where those shells are already baked. Same environment as `./setup.sh`,
  `--network host` for the service containers. The image is built and pushed
  by hand (`./infra/scripts/dev-image.sh build`) -- building it in CI cost 100
  minutes on its first attempt -- and `dev-image.sh check` fails the job before
  any test runs if `nix/` has moved since.

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

### Phase 3 — coverage (§10) — **done**

1. `api/dev/coverage.R` drives `covr::package_coverage()` (in `dev/`, not
   `tests/`, because covr runs every file under `tests/`).
2. A CI step in `test-api` writes it to the step summary and enforces
   `COVERAGE_FAIL_UNDER=60`.
3. **Measured**: 75.0% globally — above §10's 60%. Per-file the same section
   asks for 100% on seven files and four are short (`db_migrations` 75.8%,
   `ml_simulate` 90.9%, `middleware_client_ip` 80.0%, `ml_outcome` 80.4%), and
   `middleware_request_context.R`, `ml_predict.R` and `middleware_cors.R` sit
   at 0%. **Not enforced yet** — that is the follow-up: raise the four, cover
   the section 11 logger, then add `COVERAGE_FAIL_CRITICAL=1`.

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

## Plan B — R7: image size — **safe part done** (ADR-0008)

Measured first, and the premise did not survive it: `nix/system.nix` declares
ten packages, and the toolchain is inside **`R`'s own output** (`openjdk`,
`gfortran`, `gcc`, `python3` are R's `buildInputs`), not in that expression.
Splitting a Nix expression cannot reach it.

- **Done:** the three images build `nix/system-runtime.nix` = `system.nix`
  minus `nix` → closure 2608 → 2364 MB, **images −70 MB each** (share
  4.3 → 4.23, api 4.9 → 4.83, shiny 5.32 → 5.22; the closure figure is an
  upper bound because per-path `du` double-counts hard links). Rebuilt and
  smoked: every image carries an installed `taxiapi`/`taxiapp` and
  `smoke-stack.sh` passes.
- **Rejected, recorded in ADR-0008:** rewriting R with `removeReferencesTo`
  for the remaining 1.34 GB (owning a custom R derivation, revalidating
  `R CMD INSTALL` and R's startup, and `gcc` removal breaking any future
  compiled package — §1.1 limits RAM, not image size); dropping fonts from the
  API image (≈76 MB, but a test/prod asymmetry no test exercises).
- **AGENTS corrected** — the old "~2 GB from system.nix" claim was never
  measured.

---

## Plan C — `GET /state` made replica-agnostic — **done** (ADR-0009)

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

**Landed** in `b2421fc` with ADR-0009: `api/tests/testthat/test-setup-progress.R`
pins all five properties (migration and bounds, the status guard, that `/state`
answers a published 42 where the row counts would answer 99, that the answer is
identical with and without the local job table, and that age rather than
progress decides the timeout). All four suites green; the contract untouched.

## Plan D — remove the PNG byte cache from Redis — **done** (ADR-0010)

- `share/R/cache.R` keeps `sensitivity`/rate-limit/`share:views`; drops
  `png_cache_get`/`png_cache_put`.
- `share/R/routes.R` renders on every request; **`Cache-Control` and the
  Cloudflare rule stay exactly as they are** (that is the outer layer).
- `/metrics`: `png_cache_hits`/`png_cache_misses` out, `png_renders_total`
  in → **`contract/openapi.yaml` must change** (and Spectral re-run).
- Tests updated; `share:views`, bots and `/health` untouched.
- **ADR superseding part of ADR-009**, plus `CHANGELOG.md` (§7.1 goes from
  three layers to two; §11 loses two metrics), `AGENTS.md` and the runbook.

**Landed** with ADR-0010. Worth knowing: `png:cache:hits` and
`png:cache:misses` were **never incremented by anything** — they read zero from
the day they were added, which is what made them worth removing rather than
repairing. The runbook's "`share/` fails open" entry now says it does not
count the view or the render tally. All four suites green, Spectral 0 errors.

---

## Blocked — outside this repository

Everything is in [`docs/operations/first-deploy.md`](operations/first-deploy.md):
GitHub secrets for the deploy, SMTP credentials + SPF/DKIM/DMARC, the
Cloudflare cache rule and DNS, UptimeRobot, the VM swap. Plus two gaps in the
data release: `v0.0.1-data` publishes no `SHA256SUMS`, and it has no
`ReferenceDistribution.qs2`.
