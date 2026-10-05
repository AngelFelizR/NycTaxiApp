# Changelog

All notable changes to this monorepo are documented here.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/); a repo tag versions every
service at once.

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
