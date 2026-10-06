# Changelog

All notable changes to this monorepo are documented here.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/); a repo tag versions every
service at once.

## [Unreleased]

### Added

- Phase 4 UI Setup: `app/` now talks to the real contract endpoints instead of
  the retired transitional routes. `app/R/api_client.R` covers
  `validate-trip-start`, `recommend-start`, the whole `/experiments/*` surface,
  `/sensitivity` and `/waitlist`, with `X-Internal-Key`, `X-Client-IP` and
  `X-Resume-Code` on the way out, and `iso_8601()` normalising what the setup
  form accepts.
- `app/R/state.R` (`estado`): one `reactiveValues` per session holding the
  client IP from `session$request`, the one-time `resume_code`, the latest
  `DayState`, `model_progress` and the final result; `estado_ctx()` snapshots
  what a call needs and `estado_set_state()` folds every answer back in.
- `mod_setup`: bidirectional Leaflet (click a zone to select it, selecting a
  zone highlights and recenters the map), validation hints derived from
  `better_company`/`better_datetime`, the separate email/result-card/marketing
  checkboxes, the collapsed advanced-seed option with its explanation popup,
  the always-visible "Have a code?" resume section and the `?exp=` bookmark.
- `mod_confirm_modal` wired as the only path from Start The Day to Trips: it
  shows the one-time resume code with a copy button, and `nav_select` only
  happens on Continue.
- `mod_header`, plus a minimal `mod_results` panel (phase 6 adds share,
  feedback and the percentile line) and `mod_trips` rewritten against the real
  `DayState` (`experiment_id`, `next_trip`, `clock`, `history`).
- `app/dev/mock_api.R`: canned implementation of the same contract with an
  in-memory day and a `/__last` endpoint that records the `X-Client-IP` and
  `X-Internal-Key` it received. `Rscript dev/run_mock_api.R` for local work.
- `app/tests/testthat/test-shinytest2.R`: the phase-4 flow test. It starts the
  mock on a random port, runs the real app in headless Chromium, injects
  `X-Client-IP: 203.0.113.9` through the browser (what Nginx/ShinyProxy would
  set) and walks Setup → hints → Start The Day → modal → Trips → accept, then
  asserts the API saw that address. 92 app assertions in total.
- `app/default.dev.nix`: a dev shell with only the UI modules, and `chromium`
  in `nix/system.nix` so `shinytest2` finds a browser inside the container.


- Phase 3 persistence and experiments: `api/migrations/001_init.sql`
  (participants, experiments, decisions, waitlist) plus idempotent
  migrations and query helpers, and the experiment endpoints
  (`api/R/endpoints/{experiments,share_data,share_email,waitlist,metrics}.R`)
  behind `X-Internal-Key` / `X-Resume-Code`.
- Trip-day simulation (`api/R/ml/simulate.R`, section 3) and outcome rules
  (`api/R/ml/outcome.R`): 8h + 30min day, on-the-fly trips from the real
  week sample, seeded days and the `wav_match_flag` rule.
- Per-IP daily rate limits (3 experiments and 5 waitlist signups per IP and
  UTC day) hashed with `IP_HASH_SALT` and stored in Redis, fail-closed with
  503 when Redis is down; `X-RateLimit-*` headers on the way out.
- `tools/build_reference_distribution.R`: offline build of
  `ReferenceDistribution.qs2` (1,000 simulated days per company, Lyft and
  Uber, 0 dropped seeds) into `MODELS_DIR`, so `POST /experiments/{id}/finish`
  answers 200 with `user_percentile` instead of 503.
- API test suites for phase 3 (`test-simulate.R`, `test-experiments.R`,
  `test-experiments-async.R`, `test-outcome.R`, `test-rate-limit.R`):
  `[ FAIL 0 | WARN 0 | SKIP 1 | PASS 477 ]` against the compose Postgres
  and Redis (the one skip is `test-outcome.R` once the reference file is
  installed).

### Changed

- The mirai workers start lazily on the first API call (`ensure_daemons()`)
  instead of at startup, and `ggplot2` is attached on first chart
  (`ensure_ggplot2()`): together they take the app from ~4 s to ~1.5 s to
  "Listening on", against the phase-4 criterion of under 3 s. Both are torn
  down on `onStop()`.
- `api_client.R` uses `req_headers()` (`req_header()` was removed in httr2
  1.3.0) through a small `api_header()` wrapper, since the header names here
  are dynamic.
- `app/DESCRIPTION` declares the packages the code actually uses (`shinyjs`,
  `qs2`, `sf`, `jsonlite`, `promises`) and `shiny >= 1.9.0` for
  `input_task_button`/`ExtendedTask`.
- `API_CONTRACT.md` is retired: the UI speaks `contract/openapi.yaml` now, so
  the transitional 5-route list only disagreed with the authoritative contract.


- `POST /experiments` is asynchronous (divergence with section 4.6 of the
  master doc, which implies a synchronous create): it answers 201 in ~0.2 s
  with `status: setup`, `model_progress: 0` and `next_trip: null`, while the
  policy and baseline trajectories are computed by a forked child that
  persists them in chunks of five steps — a client polling
  `GET /experiments/{id}/state` watches `model_progress` climb to 99 and
  then `status: in_progress`. A day still in `setup` after 120 s is
  abandoned and `/state` answers 503, and decisions/finish answer 409
  "The day has not started yet." while the day is being prepared. The
  contract (`contract/openapi.yaml`) documents all of it.
- `api/default.dev.nix` and the root `default.nix` export
  `OMP_NUM_THREADS=1` (with `OPENBLAS_NUM_THREADS` and
  `VECLIB_MAXIMUM_THREADS`): libgomp reads the variable when R starts, and
  forking after OpenMP built its thread pool deadlocked the trajectory
  child in `futex_wait` with no CPU at all. `api/plumber.R` warns loudly
  when R started without it, and `test-experiments-async.R` skips its fork
  test in that case.

## [0.1.0] - 2026-10-04

### Added

- Monorepo first-level structure (`contract/`, `api/`, `app/`, `share/`,
  `infra/`, `tools/`, `integration/`, `nix/`, `docs/`, `.github/workflows/`).
- OpenAPI 3.1 contracts: private API (18 endpoints) and public `share`
  service (3 routes).
- `.env.example` with every environment variable; the real `.env` is gitignored.
- MIT license.
- `AGENTS.md` with repo conventions for AI agents.
- Phase 1 API base (`api/`): plumber2 service with `GET /health`,
  `POST /predict`, `POST /recommend-start`, `POST /validate-trip-start` and a
  404 catch-all; `X-Internal-Key` auth, CORS, JSON contract errors, Postgres
  pool for `/health`, mori-shared policy model with startup warm-up.
- API latency work (phase-1 criterion: `curl` < 100 ms with models loaded):
  memoised timeDate holiday calendars, faster bake methods for
  `step_impute_median` / `step_rename`, `match()`-based geospatial step and a
  tailor-free probability path; `/predict` answers in ~75 ms and RSS stays
  around 530 MB (budget 1.2 GB).
- `api/tests/` (testthat, 137 assertions) and `api/dev/` (`smoke.sh`,
  `check_syntax.R`); test infrastructure decision in
  `docs/decisions/0001-api-tests-use-fixed-postgres.md`.
- Phase 2 sensitivity (`POST /sensitivity`): ports the prototype decision
  grid to the API — hardest-zone auto-selection (Manhattan/Brooklyn/Queens
  subset), three 50x50 grids (30x30 with `X-Device: mobile`), suggestion
  metadata and always-on timing logs — backed by a `redis:7` service
  (`sens:{experiment_id}:{trip_id}:{pu}:{do}`, TTL 1h, fail-open); reads the
  real week sample via `nanoparquet` (mounted at `/data`). Hit ~0.34 s
  (< 500 ms), cold ~0.9 s (< 2.5 s), RSS ~974 MB (budget 1.2 GB);
  213 API test assertions including Redis round-trip identity checks; cache
  semantics decision in `docs/decisions/0002-sensitivity-redis-cache.md`.

### Changed

- The Shiny UI now lives in `app/` (it used to occupy the repo root).
- The project is a thin Shiny client for the plumber2 API; domain logic lives
  in the API.
