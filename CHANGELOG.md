# Changelog

All notable changes to this monorepo are documented here.
The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/); a repo tag versions every
service at once.

**This file is also where divergences from the master document are recorded.**
`04 - Documento Maestro de Decisiones del Proyecto.md` is never edited (it has
exactly one commit, its creation), so when the code does something the document
does not describe -- or describes differently -- the difference is written
here, under `Changed`, naming the section. Annotated, not corrected.
Precedents: the asynchronous create vs §4.6, `shared/` vs §1.3 and §6.4, and
the two endpoints §5.2 documents but the API never implemented.

Architectural tradeoffs do not live here: they get an ADR in
`docs/decisions/`. See `docs/decisions/README.md` for which kind of decision
goes where.

## [Unreleased]

### Added

- **Phase 6, the `share/` half: the public share service.** Its own package
  (`share/DESCRIPTION`), its own dev shell (`share/default.dev.nix`) and its
  own test suite (150 assertions). Three routes from
  `contract/share.openapi.yaml`: `GET /share/{token}.png` (1200x630 card,
  `patchwork` + `ragg`, bytes cached in Redis for 24 h, served with
  `max-age=86400, s-maxage=604800`), `GET /share/{token}` (static HTML with
  Open Graph in the `<head>`, **no JavaScript at all**, `Cache-Control:
  no-store` so the view counter can see the hit) and `POST /waitlist`
  (validation + forward). Plus `GET /health` for the container healthcheck.
  No database credentials and no models exist here by design: every number
  comes from `GET /share-data/{token}` over the Docker network with
  `X-Internal-Key` + `X-Client-IP`.
- `share/R/bots.R` + `share/R/cache.R`: the User-Agent filter of 7.4 (crawlers
  do not increment `share:views:{token}`) and the two Redis keys the service
  owns. Both fail open -- if Redis is down the card is rendered fresh and the
  view is simply not counted.
- `share/R/routes.R` holds the handlers and a `share_api()` builder so the
  tests can build the app without calling `api_run()`.
- `nix/r-share.nix` (plumber2, httr2, patchwork, ragg, redux) for the service
  and its phase-7 image; `nix/r-dev.nix` gained `callr`, which
  `test-routes.R` uses to boot the service and a stub of the API as child
  processes.
- **`mod_share`: the four share buttons and the second email prompt (6.5).**
  Download PNG, Copy link, Share on X and Share on LinkedIn live in their own
  module mounted inside `mod_results`, plus "Email me my card" which asks for
  an address only when Setup never got one (5.6: `email` is optional in the
  body then). The three links are plain `<a>` elements the server points at
  the card once `estado$share_token` exists -- section 6.1.1 forbids
  `renderUI` for structure, and a real anchor keeps the browser's user
  activation so X and LinkedIn open a tab instead of being blocked, and stays
  middle-clickable. `api_share_email` joins the client, `SHARE_BASE_URL` gives
  them their origin, and every click writes `{"event":"share_click",
  "channel":"..."}` to stderr (7.4). The mock grew `/experiments/{id}/share-email`
  and reports the address it received through `/__last`.

- Phase 6, the app half: `mod_results` shows the finished day with the six
  KPIs of section 6.5 (Total Earnings, Hourly Wage, vs Policy, Trips Accepted,
  Trips Rejected, % Following Policy), the three cumulative curves in
  `renderGirafe`, the percentile as a sentence under them (4.6 -- never a
  seventh KPI), the "Custom seed — unofficial" badge (3.3), the neutral
  `no_rides` notice (3.8), a collapsed Technical details block with the
  experiment id, and the buttons that lead to feedback and to a new day.
- `mod_feedback`: the post-game modal (rating 1-5 + comment + public-display
  consent, off by default) that answers `POST /experiments/{id}/feedback`. It
  refuses to submit without a rating and keeps the dialog open until the API
  accepts.
- The day now actually ends: nothing but `POST /finish` computes `outcome` and
  `user_percentile` (4.6, "siempre en el servidor"), so `mod_trips` calls it
  when `shift_over()` sees `pending_hours <= 0`, `state.R` folds the returned
  Experiment into `estado` without losing the history the curves need, and
  `app.R` moves to Results. `api_feedback` joins the client.
- `dev/mock_api.R` gained `/experiments/{id}` and `/feedback`, a trailing
  catch-all so an unknown path answers 404 instead of an empty 200, and a
  `mock_result()`/`mock_experiment()` pair that reproduces the section 3.10
  outcome precedence -- so Results can be exercised without models or a
  database.

- **`shared/`: una sola especificación visual para `app/` y `share/`.**
  `shared/curves.yaml` (las 3 curvas: orden, etiqueta, color) y
  `shared/brand.yaml` (`primary`, `primary_dark`) se leen desde ambos
  frontends mediante `shared/load.R`, que localiza el directorio por
  candidatos, parsea una sola vez y **valida** lo que YAML no puede (3 series
  en orden `user, policy, baseline`, etiquetas no vacías ni repetidas, colores
  hex únicos, `primary != primary_dark`). Los hex literales desaparecen de
  `app/R/` y `share/R/`: `grep -rn "6d5dfc" app/R share/R` vuelve vacío.
  `nix/r-shared.nix` aporta `yaml` (importado por `r-app.nix` y por el shell
  de `share/`) y el `Dockerfile` gana la capa **9c**, que tiene que ir antes de
  la 10 o el shell horneado sale sin `yaml`. Alternativas descartadas y el
  porqué en `docs/decisions/0003-shared-visual-config.md`.
- `app/R/shared_config.R`: puente dentro de `R/` que sourcea `shared/load.R`.
  Shiny fuentea `R/*.R` **antes** del cuerpo de `app.R` (verificado con un
  probe), así que `strings.R` no puede calcular sus `label_curve_*` desde
  `curve_labels()` si la carga vive en `app.R`. Solo funciona por el orden
  alfabético de `R/` (`constants` -> `shared_config` -> `state` -> `strings`).

- **Phase 7 (infra), written and linted but never built or deployed.**
  - `docker-compose.prod.yml` at the root: the canonical deployment, written as
    a **standalone file rather than an override**. Compose *appends* `ports:`
    and `networks:` across files, so layering it over the dev compose would
    have published 2222/5432/6379 in production -- exactly what §9.3 and the
    phase-7 smoke test forbid. Three networks with `name:` pinned (otherwise
    compose renames them `nyctaxi_nyctaxi_api_net` and ShinyProxy's
    `container-network` would not find them), the limits of §1.1, `shm_size: 2g`
    for the API's `mori`, json-file logging 500m x 3 and `ENV=production`.
  - `infra/nginx/`: `nginx.conf` routing only to ShinyProxy and `share` with
    `/api/` answering 404, `proxy_intercept_errors` + `error_page 503` into a
    `capacity-full.html` (demo slot, waitlist form posting JSON, self-reload
    every 60 s), 10 r/s on `/share/` and `/waitlist`, Cloudflare's address
    ranges via `set_real_ip_from`, and a WebSocket upgrade for Shiny.
    `nginx -t` passes without warnings.
  - `infra/shinyproxy/application.yml` (§8.3): `max-total-instances: 10`,
    `allow-container-re-use`, `container-network: nyctaxi_api_net`, the data
    volume read-only and the three variables a Shiny container needs.
  - `infra/scripts/` -- four scripts, all passing `shellcheck`: `backup.sh`
    (§8.5), `restore_test.sh` (restores into a throwaway container and
    compares the table count), `disk_check.sh` (hourly cron, SMTP alert above
    80% with a 6 h cooldown) and `fetch-assets.sh` (§4.5: downloads the release
    and verifies SHA-256, idempotent, **aborts without touching anything** when
    verification fails).
  - `.github/workflows/ci.yml` (§8.6): `test-contract` (spectral in docker),
    `test-api` (Postgres and Redis as *service containers* -- ADR 0001, not
    testcontainers), `test-shiny`, `test-share`, a guarded `test-integration`,
    `build-{api,shiny,share}` to GHCR and `deploy` with its exposure smoke
    test. Per-service filtering with `dorny/paths-filter`; builds run on
    `ubuntu-24.04-arm` because the VM is ARM and a Nix closure under QEMU does
    not fit in a job. **Validated with `actionlint` (0 errors); never run.**
  - `api/Dockerfile`, `app/Dockerfile`, `share/Dockerfile`: multi-stage on
    `nixos/nix:2.35.2` -- stage 1 assembles the Nix closure with
    `nix-store -qR` and tars it, stage 2 extracts exactly that. The
    `WORKDIR /app` + `<service>` + `shared/` layout mirrors the repository
    because `root` is computed as the parent of the service. `docker build
    --check` passes on all three; **no image has been built**.
  - The three `default.prod.nix` variants that were still missing, plus a root
    `.dockerignore`.

- **`docs/operations/runbook.md` (§8.8)** — the living operations document,
  starting with the four procedures the master document asks for and adding
  two we already know from the code: disk full (the alert, then what to prune
  and in which order, and why `docker volume prune` is never the answer), PII
  erasure on request (§9.1, including that backups keep the address for 28
  days and `ip_hash` is not something we can erase by), rotating
  `API_INTERNAL_KEY` (restart order, because ShinyProxy interpolates it into
  containers that are already running), ShinyProxy not delivering
  `X-Client-IP` (walk the three hops, and point at the §5.4 Plan B rather
  than improvising), the API wedged in `setup` (libgomp/`futex_wait`), and
  `share/` answering 503. Plus a short routine-checks list.
- **`integration/` is no longer an empty skeleton.** A real package with a
  `DESCRIPTION` and 57 assertions that compare the three descriptions of the
  system: every route `api/plumber.R` registers against `contract/openapi.yaml`,
  the three public routes of `share/R/routes.R` against
  `share.openapi.yaml`, and every path `app/R/api_client.R` and
  `share/R/api_client.R` actually calls against both (parameter names are
  normalised, since the client only knows `experiment_id` where the contract
  says `{id}`). **It writes down a real divergence instead of hiding it:**
  section 5.2 and the contract list 18 endpoints while the API registers 16 —
  `/trips/sample` and `/zones/geojson` were never built and have no client
  (6.1.3 makes the app preload zones from the data volume instead). The test
  requires that difference to be exactly that pair, so it fails the moment
  someone implements them or drops them from the contract.

- **The three phase-7 images were actually built and smoke-tested**, which
  closes the last item on the phase-7 deliverable list:
  - `nyc-taxi-share` 4.3 GB -- starts, `/health` answers 200 with
    `redis: unavailable` (fail-open, by design), an unknown token answers 503
    JSON because no API is reachable, and **RSS is 199 MB against §1.1's
    256 MB limit**.
  - `nyc-taxi-api` 4.9 GB -- `Listening … RSS 373 MB`, and with no models, no
    dataset, no Postgres and no Redis it degrades with readable messages
    instead of dying, which is what the `tryCatch` warmup is for.
  - `nyc-taxi-shiny` 5.32 GB -- `Listening on :3838`, `GET /` 200, and
    **`GET /privacy.html` 200 with the link present twice** (Setup and the
    footer). It starting is also the proof that `shared/load.R` resolves
    inside the image: without `shared/`, `strings.R` would fail before the
    first `Listening`.
  Builds take ~10/45/15 minutes because a fresh build store compiles the R
  packages from source -- the `rstats-on-nix.cachix.org` cache does not cover
  these pins. BuildKit's cache amortises it between runs.
- **`app/www/privacy.html` (§9.1), mandatory before publishing and previously
  404.** The Setup email block has linked to it since phase 4, so the notice
  the document requires simply did not exist. It is a static, script-free page
  covering the six points §9.1 lists (what is stored, what for, localStorage
  vs cookies, retention, who touches it, how to ask for erasure), linked from
  Setup, from a new `footer` on `page_navbar` and from `mod_share`'s email
  modal -- the three places §9.1 asks for. `test-privacy.R` (22 assertions)
  fails if any of the six goes missing or any of the links goes away.
- **`.env.example` now documents every variable the services read.** It was
  missing `SMTP_FROM`, `SMTP_STARTTLS`, `SHARE_URL`, `SHARE_HOST/PORT`,
  `SHARED_DIR`, `TAXI_MODELS_DIR`, `TAXI_DATA_DIR`, `API_HOST/PORT`,
  `API_TRACE` and `API_EXPERIMENTS_SYNC` -- nine of them would have been
  discovered by reading the source. An integration test now scans `api/R`,
  `app/R`, `share/R` and `tools/` for `Sys.getenv()` and fails when a variable
  is read but undocumented, or documented but unread.
- **`docs/operations/first-deploy.md`**: the checklist for everything that
  cannot be done from inside the repository -- GitHub secrets, the VM (swap,
  directory layout, cron), the DNS records (SPF, DKIM, DMARC with example
  values), the Cloudflare cache rule for `/share/*.png`, the availability
  monitor, and the post-deploy smoke test. It also spells out the two release
  gaps that make the first deploy abort by design.
- Redundant `.gitkeep` files removed from every directory that has content;
  only `docs/investigation-phases/` keeps one.

- **`infra/scripts/smoke-stack.sh` + `docker-compose.smoke.yml`: the production
  stack now actually runs on a workstation.** Six assertions the parsers could
  not make: §10(a) `/api/health` -> 404 through the edge, §10(c) only 80 and
  443 published, `GET /` -> 200 through Nginx and ShinyProxy,
  `GET /share/<unknown>` -> 404 `application/json` (edge -> share -> API),
  §10(e) `share` holds no `POSTGRES_*`, and §8.2's `error_page 503` serving
  `capacity-full.html`. The overlay only re-points `/models` and `/data` at the
  directories `.env` already has and swaps `/etc/letsencrypt` for a
  self-signed certificate, so nothing outside the repository is touched; the
  production file keeps its `/srv/nyctaxi/...` paths for the VM. Image tags
  became `${NYCTAXI_TAG:-latest}` so the same file runs against the images CI
  pushes and against the ones built locally.
- `app_data_candidates()`: `app_data_dir()` now also looks in `/app/data`,
  which is where §8.3 mounts the volume for the Shiny containers. It was not a
  candidate, so in production every Shiny instance would have looked for
  `ZonesShapes.qs2` in four wrong places and drawn an empty map with nothing
  in the logs to say why.

- **The section-10 tests that did not exist, and the bug they found.**
  - `smoke-stack.sh` gained §10(c) and §10(d): a throwaway container on
    `nyctaxi_api_net` reaches `api:8000` but **cannot resolve** `postgres:5432`
    or `redis:6379` (DNS itself fails -- they are only on `data_net`), and
    `GET /health` without `X-Internal-Key` answers 403 through the real
    router. Eleven hard checks now, not six.
  - `integration/test-router-auth.R`: `internal_auth_header` is registered
    exactly once, as a catch-all on `/*`, **before** the first route --
    plumber2 aborts at startup if that order is wrong, and nothing else
    noticed if the hook were removed.
  - `app/test-session-isolation.R` (§6.1.5): no file under `app/` uses `<<-`
    or `assign()`, the only environment is the preloaded-data cache in
    `constants.R`, and two `init_estado()` calls cannot see each other. This
    is what `allow-container-re-use: true` actually depends on.
  - `share/test-no-pii.R` (§10): `ShareDataResponse` declares no
    `experiment_id`/`email`/`name`/`resume_code`/`ip_hash`, and the renderer
    picks its fields -- a payload carrying all four renders a page with none
    of them while the whitelisted identity still appears.
  - `test-shinytest2.R` gained the case §10 spells out: a mock answering 429
    (via a new `POST /__fail` control route) must surface its own message.

- **`docs/decisions/0004-container-hardening.md`**: no capabilities, read-only
  roots, an unprivileged user and CSP on the static pages -- plus the two
  things this deliberately does *not* fix (ShinyProxy keeps its Docker socket;
  the ephemeral Shiny containers cannot be hardened through it) and the CSP
  on `/`, which is deferred until something can drive a real session to
  verify it.
- `/.well-known/security.txt` (served from the document root, which needed a
  location in the **443** server -- the one under port 80 never sees an HTTPS
  request) and a Content-Security-Policy on the two static responses: `script-src 'none'` on `/share/*`, which section 7.2 already
  says is never JavaScript, and a tight policy on `capacity-full.html`, which
  does run one inline script for its waitlist form. The headers live in
  `nginx/snippets/security-headers.conf` because nginx does not inherit
  `add_header` into a location that defines its own.

- **ADR-005 and `POST /render-card`: `share-email` finally delivers.** The
  endpoint was structurally unable to succeed (see Fixed).
- **Release tooling**: `infra/scripts/make-manifest.sh` builds `SHA256SUMS`
  for all six assets, which live in *two* directories locally, so a plain
  `sha256sum *` would cover half of them; and
  `infra/scripts/test-fetch-assets.sh`, a hermetic self-test (six invented
  files, no network, no real `.env`) covering the happy path, the idempotent
  re-run, a manifest with entries missing -- it must name **all** of them
  rather than fail one at a time -- and a wrong hash, which must leave the
  destination untouched. `fetch-assets.sh` now reports every missing entry
  before downloading anything instead of aborting on the first.
- **A local SMTP catcher** (`mailpit`) in the development compose, plus
  `TAXI_API_URL`, `SHARE_URL` and `SMTP_URL` in the dev container's
  environment. `.env` is shared with production and describes the Docker
  network, while the API runs *inside* that container, so the local addresses
  are set where compose wins over `env_file`.
- Two new E2E steps (10b/10c): `POST /share-email` after `finish`, then read
  the message back from the catcher and assert the card arrived as an
  attachment. Section 5.6 says the promise of "you will receive your card by
  email" is real; now something proves it.

- **`infra/scripts/health_check.sh`**: the private services are no longer
  unmonitored. Section 8.1's external monitor watches the landing page of
  ShinyProxy, which does not depend on the API -- so a dead database kept a
  green dashboard while the first visitor to press "Validate" found out. This
  probes `/health` on api and share, `pg_isready` and `redis-cli ping`, from
  the host, and mails through the same SMTP path as `disk_check.sh` with a 6 h
  cooldown. A green run clears the cooldown so the next incident alerts.
- **`disk_check.sh` now also watches the backups.** Nothing else notices when
  cron stops running: a missing dump is invisible until someone needs one. It
  fails if there is no dump or if the newest is older than 25 h, and both
  problems are reported together rather than one at a time.
- **Section 11's structured request log.** One JSON line per request with
  `method`, `path`, `status`, `duration_ms`, `correlation_id` and `ip_hash`,
  and no clear IP anywhere in it. `X-Request-Id` is accepted from the edge and
  generated otherwise; Nginx's own log line carries `$request_id` alongside
  `rt=`.

- **Response-body conformance with `contract/openapi.yaml`** (ADR-0006):
  `api/tests/testthat/test-contract-conformance.R` drives the real handlers
  and checks each response -- status and body -- against the schema the
  contract names for exactly that route and code. A status the contract does
  not document fails the test, which is how it found the four defects below.
  The check runs on `jsonvalidate` + V8 (real ajv), with `yaml`, `jsonvalidate`
  and `V8` added to `api/default.dev.nix` and to nothing else -- never to the
  production image.

- **`api/` is an R package** (ADR-0007): `NAMESPACE`, `R/` flat with the
  layer in the file name (`db_pool.R`, `ml_predict.R`,
  `endpoint_predict.R`, `middleware_client_ip.R`, …), `R CMD INSTALL` in the
  image and `pkgload::load_all()` in development. `plumber.R` and the test
  bootstrap stopped carrying 30-entry `source()` lists; the S3 methods of the
  recipes step are declared instead of being found by accident in
  `globalenv()`; the three functions the tests override are mocked with
  `local_mocked_bindings()` instead of `assign(…, globalenv())`, which can
  no longer reach a namespace binding. `pkgload` and `covr` were added to the
  dev shells only. This is what makes section 10's coverage measurable.

- **`app/` is an R package too** (`taxiapp`, same decision as `api/` in
  ADR-0007): `NAMESPACE`, `R/` flat — the nine files that lived in
  `R/modules/` are now siblings of the rest — `R CMD INSTALL` in the image and
  `library()` at boot, `pkgload::load_all()` in development. A new
  `app/R/_disable_autoload.R` stops Shiny's `loadSupport()` from sourcing the
  directory into the environment `app.R` runs in, which would leave two copies
  of every object (including `constants_state`).
- **`shinytest2` moved from `nix/r-shiny.nix` to `nix/test-tools.nix`**, so
  the UI image stops carrying a browser driver it never runs. The dev shell
  names it in `R_LIBS_SITE` — R only sees what that variable names, and
  leaving it out made the flow test skip with "{shinytest2} is not installed".

- **Section 10's coverage, measured for the first time.**
  `api/dev/coverage.R` drives `covr::package_coverage()` and prints the global
  figure plus the seven critical files the section names. Getting there needed
  three things the package now provides: a `NAMESPACE`, `tests/testthat.R`
  anchored on its own file (covr runs it from a temporary tree, where
  `tests/testthat` does not exist), and `TAXI_API_DIR` exported by the script
  so `helper-load.R` and `contract_path()` follow the tests back to the
  repository instead of resolving `..` against the temp install. CI runs it
  with `COVERAGE_FAIL_UNDER=60`.
- **The first measurement**: 75.0% globally, above the 60% section 10 asks
  for. Four of the seven critical files are short of the 100% it also asks
  for — `db_migrations` 75.8%, `ml_simulate` 90.9%, `middleware_client_ip`
  80.0%, `ml_outcome` 80.4% — and three files come back at 0%:
  `middleware_request_context.R` (the section 11 logger), `ml_predict.R` and
  `middleware_cors.R`. The per-file bar is reported but not enforced until
  those are agreed; the global one is.

- **The deployment images build `nix/system-runtime.nix`** (ADR-0008):
  `nix/system.nix` minus `nix`, which the base image already provides and no
  container ever runs. Measured on the API pin the closure goes 2608 -> 2364
  MB (-244 MB), and the images themselves lose about 70 MB each (share
  4.3 -> 4.23 GB, api 4.9 -> 4.83, shiny 5.32 -> 5.22): summing `du` per store
  path double-counts hard links, so the closure figure is an upper bound.
  Development shells keep `system.nix` — a shell is where
  you run `nix` — and the two differ by an unused binary rather than by a
  behaviour, so there is no test/prod asymmetry.

- **`GET /state` no longer derives its `model_progress`** (ADR-0009): the
  forked child publishes the percentage on the `experiments` row every five
  steps, guarded by `AND status = 'setup'` so a stale child gets zero rows
  instead of overwriting a day that has moved on. The reader now takes one
  column instead of counting rows in two tables, and reads it with
  `FOR SHARE`. `api/migrations/002_setup_progress.sql` adds
  `setup_progress SMALLINT` with a `BETWEEN 0 AND 99` check; `NULL` means
  nothing has been published and renders as 0. `model_state$traj_jobs` keeps
  exactly the job it had -- a fork table to reap zombies from -- and is never
  read to build a response. The timeout is untouched: still `created_at`, so
  a dead child leaves a frozen number and the row is still retired.
  `contract/openapi.yaml` is unchanged, by design.

- **The card has one cache, and it is the edge** (ADR-0010):
  `share/R/routes.R` renders on every request that reaches the service, and
  `png_cache_get`/`png_cache_put`/`png_cache_del` leave `share/R/cache.R`.
  `Cache-Control: public, max-age=86400, s-maxage=604800` is untouched — it
  is the cache now. What made this worth doing: **nothing ever incremented
  `png:cache:hits` or `png:cache:misses`**, so `/metrics` has reported zero
  for both while a 24 h Redis TTL hid the renders they were supposed to
  count. In their place `share/` increments a global `png:renders` and the API
  reports `png_renders_total`; `contract/openapi.yaml` moved with it and
  Spectral passes.

- **CI runs the tests inside the development image, not on the runner's Nix.**
  The four test jobs pull `ghcr.io/angelfelizr/nyc-taxi-dev:latest` and run
  `nix-shell` **inside the container** with the repository mounted at
  `/root/NycTaxiApp` and `--network host`, so they reach the Postgres and
  Redis service containers. The image is **built and pushed by hand**
  (`./infra/scripts/dev-image.sh build`) rather than in CI: `nix/` changes far
  less often than the code, and the first CI attempt at building it spent 100
  minutes compiling packages the binary cache does not cover. The image bakes
  the shells the tests run in (a new Dockerfile layer for
  `api/default.dev.nix` and `share/default.dev.nix`), and `dev-image.sh check`
  refuses to run a single test when the image's `nix-hash` label does not
  match the checkout -- a run against different pins would pass or fail for a
  reason that is not in the commit.
  `cachix/install-nix-action` is gone from every test job: the environment
  now comes from the same pins that produce `./setup.sh` locally, which is the
  whole point — a runner and a laptop could otherwise disagree about the
  filesystem, the Nix version and the store. The shell-build retries went with
  it, because those shells are already built into the image.

- **Section 10's coverage target is met and now enforced.** Three new test
  files close what the report named: `test-request-context.R` (the section 11
  logger, which had never been tested at all), `test-cors-and-predict.R`
  (the CORS origin rule and the "nothing is loaded" answers the 503s depend
  on) and `test-coverage-critical.R` (the branches a happy-path day never
  reaches: migrations that cannot apply, a whitespace client IP, a day with no
  data, a replay that disagrees with what was stored, a step cap, and every
  branch of the Results and share copy -- the one section 10 asks for by name).
  **75.0% -> 80.2% globally, and all seven critical files at 100%** (three
  were already there; `db_migrations` 75.8 -> 100, `ml_simulate` 90.9 -> 100,
  `middleware_client_ip` 80 -> 100, `ml_outcome` 80.4 -> 100).
  CI now holds both bars: `COVERAGE_FAIL_UNDER=60` and
  `COVERAGE_FAIL_CRITICAL=1`.

- **Section 12, the parts a machine can check** (`app/tests/testthat/test-accessibility.R`):
  `prefers-reduced-motion` collapses every animation duration in the app,
  Bootstrap and Leaflet alike (the app's own `transition` on the pending-time
  fill is the one it owns); both `girafe()` charts carry `role="img"` and an
  `aria-label` that says what they show, because an SVG is a picture to a
  screen reader; and every text pair in both themes is computed against WCAG
  2.1 and must clear 4.5:1. The pending clock is asserted to print its hours
  as text, so §3.11's "never colour alone" has a check. What stays manual
  (`pa11y`, the 390px checklist, the WebAIM sign-off) is written down in the
  runbook instead.
- **`taxi_palette(mode)`**: the colours the app draws are now data rather than
  two inline CSS blocks, so the contrast test reads the values the stylesheet
  is built from. `theme_taxi()` renders the same rules from it.

- **The runtime images run R without the toolchain R was built with**
  (ADR-0011). `nix/r-slim.nix` strips `openjdk`, `gcc`, `gfortran`,
  `graphviz` and the `cairo`/`pango` dev headers out of R's own output with
  `remove-references-to`, over the four text files that hold those paths and
  never near a binary: `gfortran-lib` and `gcc-lib`, which `libR.so` and
  `bin/exec/R` actually need, are untouched. Measured, same pin: the closure of
  `system.nix` goes **2608 MB / 284 paths -> 585 MB / 146 paths**, and R still
  starts, keeps `en_US.UTF-8` and installs both packages. `glibc-locales` is
  deliberately still there: `LANG` depends on it and this repository has
  already paid for a locale problem. Both `system.nix` and
  `system-runtime.nix` import it, each instantiated with its own pin, so dev
  and production run the same R.
- **Cypress is the UI's end-to-end and load tool** (ADR-0012), and
  `shinytest2` goes once its 14 scenarios have landed. The chain phase 8
  assumed does not exist: `shinyloadtest` 1.2.1 only *analyses* the output of
  `shinycannon`, which is not in the pin, ships as a jar needing a JDK we do
  not carry, and takes a recording produced while a human drives a browser.
  What landed now: `nix/node.nix` plus Dockerfile layer 11 (node from Nix,
  Cypress from npm because `pkgs.cypress` is marked insecure, Electron's
  libraries from apt, `cypress verify` running **in the build** so a broken
  toolchain fails there), `app/cypress.config.cjs`, `app/dev/e2e.sh` (owns the
  app and the mock API, and says why the app never answered rather than
  timing out silently) and the first spec. **`setup-screen.cy.js`: 2 passing,
  against the real app, with the mock API.**
- **The development image grew from 7.51 GB to 8.97 GB** with node, Cypress
  and the Electron libraries. It is a development image: no deployment one
  carries any of it.
- **The development image is fed by a signed local Nix binary cache**
  (ADR-0013). The public caches do not cover what this image compiles:
  probing real store paths from the build, `rstats-on-nix.cachix.org` is
  public but supplied **6 of the 400** paths the API layer fetched (394 came
  from `cache.nixos.org`), and `r-purrr-1.2.0` and `R-4.5.2` are **404 on
  both** — while `nix/r-slim.nix` deliberately changed R's derivation, so
  `R-4.6.1` is no longer the cached binary either. A change in `nix/` thus
  recompiled R (747 s) and 134 R packages (1099 s): **3223 s of layers, ~64
  min with the push**. `dev-image.sh build` now serves
  `~/.cache/nyctaxi-nixcache` on `127.0.0.1:8093` for the duration of the
  build, signs the closure of the profiles from the image it just built, and
  Docker layer caching could never have been the answer — the layer that has
  to re-run is the one holding the packages. The rebuild that landed this:
  **3223 s → 347 s (9.3×)**, API layer 1098.7 s → 36.9 s, zero derivations
  built, 1052 paths from the loopback cache. The server being down is not a
  failure (Nix re-queries `nix-cache-info` once, ~1 s); what must not be
  dropped is `--network=host`, which is part of every layer's cache key.
  Image 8.97 GB → 8.91 GB.
- **The browser suite tests the real API, and the mock is gone** (ADR-0014).
  ADR-0012 left `app/dev/mock_api.R` in place because "Cypress needs an API to
  talk to"; putting the two side by side showed what that cost. The mock's
  canned `better_datetime` was `2024-05-12T20:00:00Z` where the API answers
  `2024-05-14T15:00:00Z`, and for the form's defaults the API echoes the input
  back, so `validation_hints()` shows **no** datetime hint at all — the
  scenario that asserted the canned one would have failed against the service
  it stood in for. What landed: `app/dev/e2e.sh` starts the API, `share/` and
  `app/dev/e2e-proxy.js`, a proxy that carries `X-Client-IP: 203.0.113.9` on
  the page load **and on the WebSocket handshake** — Shiny reads the header
  there and `cy.intercept` cannot reach a handshake, which is the assumption
  `docs/PLANS.md` had and corrected. Four specs (`setup-screen`, `full-day`,
  `rate-limit`, `client-ip`) cover the 14 scenarios, including the **real
  429**: the limiter spends three attempts a day per IP, counts the ones that
  fail validation too, and the fourth returns the API's own message instead of
  one a stub was told to send. The percentile is the model's (`99th` of 1,000
  simulated days), the email prompt goes through the real `share/` and
  mailpit, and Redis is reset per spec with `cy.task("redis_flush_db")` — raw
  RESP over a socket, no npm dependency — so the order of the run cannot
  decide the outcome. Deleted: `app/dev/mock_api.R`,
  `app/dev/run_mock_api.R` and `app/tests/testthat/test-shinytest2.R` (541
  lines, 14 blocks). `test-shiny` in CI now carries Postgres, Redis, mailpit
  and the release assets verified by `fetch-assets.sh`.
- **`docs/TOPICS.md`: a link-only index of where everything lives.** One
  entry per topic — tool/subject → canonical file, ADR and master-doc
  section — so the "which file answers this?" question stops costing a
  read-through of five documents. It carries no prose of its own (it cannot
  contradict what it points at), is extended in the same commit as whatever
  it indexes, and is referenced from AGENTS and from the taxonomy in
  `docs/decisions/README.md`, which gains a fifth rule: a `Fixed` entry in
  this file now ends with a `**Lesson:**` line — the portable lesson in one
  sentence, so the next reader extracts it with a `grep` instead of a close
  reading. Past entries are not rewritten.

### Changed
- **§7.1 describes three layers for the card and there are now two.** The
  master document puts a Redis cache in front of the render and the edge in
  front of that; the Redis layer is gone and only the edge remains. Annotated
  here — §7.1's actual promises (server-side render, cacheable at the edge)
  are unchanged, and so is `Cache-Control`.
- **§11's `/metrics` loses `png_cache_hits` and `png_cache_misses`** and gains
  `png_renders_total`. The two it lost could never have moved: nothing wrote
  them.

- **AGENTS' "Peso de las images" section was wrong and is now measured.** It
  said the ~2 GB of toolchain "vienen de `nix/system.nix`" and that splitting
  that expression would recover it. The expression declares ten packages and
  closes at 2608 MB; the toolchain is inside **`R`'s own output**, which
  references `openjdk`, `gfortran`, `gcc` and `python3` because they are its
  `buildInputs`. Separating a Nix expression cannot remove it — the record of
  why that is not worth doing is ADR-0008.

- **`app/R/modules/` is gone.** §6.2 of the master document draws that
  directory, and an R package cannot have one: R ignores subdirectories of
  `R/`, which is exactly why the modules had to move. Annotated here; the
  document is not edited.

- **`plumber2`'s `@serializer png` is a graphics serializer: it discards
  `response$body`.** It opens a device, captures whatever was drawn and
  ignores the body, so the card came back as a blank 1.8 KB PNG while the
  handler had already rendered 51 KB of real pixels. Every share route now
  declares the JSON serializer (what every error in the contract needs) and
  the success paths opt into `image/png` / `text/html` *inside the handler*
  with `response$set_formatter(..., default = ...)` -- plumber2's own
  negotiation would otherwise let `Accept: */*` pick the image and hide the
  error document. The PNG formatter is a pass-through: the bytes are already
  produced by `share_png()`.
- **`/finish` now sends `{}`.** The route declares no `requestBody`, and the
  real API answers it either way (verified: handler runs with and without one),
  but this plumber2 build only dispatches a POST route when the request
  carries a JSON body: without it the mock fell through to the catch-all.
  `api/dev/e2e_experiments.sh` already sent `-d '{}'` for the same reason.
- `girafe_options()` is an in-place modifier that takes the girafe as its
  first argument, not an option factory: wrapping each option in it made
  `girafe()` reject the widget with "`x` must be a girafe object". The options
  go in `options = list(...)`.
- Every output inside a `conditionalPanel` now sets
  `suspendWhenHidden = FALSE`: an output that only computes once its panel is
  visible stays blank when the panel is revealed by a flag it cannot see.
  That is why Results rendered empty KPIs while `filled_on` was already true.
- `c(label_curve_user = ...)` takes the *literal* name, not the string the
  variable holds; the curve colours now get their names assigned after the
  vector is built.
- Startup is 2.24-2.51 s at "Listening on" against the <3 s criterion.

- Phase 5 UI Trips: the screen split into `mod_trip_card` (the offer, the map
  and the decision) and `mod_sensitivity` (the what-if zone picker), both under
  `R/modules/` with the other modules -- `mod_setup.R` and `mod_trips.R` moved
  there too, matching the file layout of section 6.2, and `helper-load.R` now
  mirrors `app.R` instead of listing files by hand.
- `mod_trips` got the sidebar (3/9 on large screens, stacked on small), three
  KPIs, the pending-time progress bar and the keyboard-hint footer. The hours
  are `renderText`; the bar's width and colour level are pushed with shinyjs
  because section 6.1.1 forbids `renderUI` for structure.
- `www/js/shortcuts.js`: ←/→ preselect Reject/Accept, Enter sends the
  preselection through the very same button a click uses, `?` opens the help
  dialog and Esc closes it. Keys never send a decision on their own (6.5), and
  the hints are hidden entirely on touch devices. Escape is reported to the
  server because Shiny binds it to the modal element, which only sees the
  event when the focus is inside it.
- Cumulative chart and the sensitivity boundary are now `renderGirafe`
  (interactive tooltips). Section 3.11 holds: the three curves are purple plus
  two greys, the boundary uses a probability ramp, and the sidebar shows no
  running comparison against the model.
- The Leaflet route is updated with `leafletProxy()` instead of re-rendering
  the widget, so a new offer keeps the player's zoom and pan; the tile layer
  follows the dark-mode toggle the same way (6.5).
- `test-shinytest2.R` grew to 43 assertions: it walks the whole day -- sidebar,
  sized clock bar, shortcut footer, arrow/Enter preselection, the `?`/Esc
  dialog, every decision until the shift closes, Results and the feedback
  modal.
- **Divergence annotated, document untouched (section 6.5):** the master doc
  writes `layout_columns(col_widths = c(3, 9), breakpoints = breakpoints(...))`,
  but bslib 0.12.0 has no `breakpoints` argument -- it lands in `...` and comes
  out as a useless `breakpoints="c(12, 12) c(3, 9)"` attribute while the md/lg
  widths are dropped. The breakpoints object goes in `col_widths` instead, and
  that renders `col-widths-md="12,12" col-widths-lg="3,9"` as intended.
- **Divergence annotated:** section 6.5 says the sidebar KPIs are "actualizados
  por `updateTextInput` sobre `textOutput`", which cannot work -- `updateTextInput`
  writes to a `textInput`. They are `textOutput` + `renderText`, which section
  6.1.1 explicitly allows for content.
- Startup cost of the interactive charts: building `ggiraph::girafeOutput`
  loads the ggplot2/ggiraph namespaces and costs ~1.1 s, taking the app from
  ~1.4 s to ~2.2-2.4 s at "Listening on". Still inside the phase-4 criterion
  of <3 s, but it is now most of the budget -- do not move `ggiraph` (or any
  other namespace load) earlier without re-measuring.

- Nix dependency split, so no image ships what it never runs:
  `nix/pkgs-app.nix` (UI pin, same tarball as `pkgs.nix` today so nothing
  rebuilds) and `nix/r-app.nix` (the whole UI in one expression — what the
  phase-7 image will build), plus `nix/test-tools.nix` holding only the
  chromium the shinytest2 flow test drives. `nix/system.nix`,
  `r-shiny.nix`, `r-geo.nix`, `r-plotting.nix` and `r-dev.nix` are now
  functions `{ pkgs ? import ./pkgs.nix }:` — `nix-build` auto-calls the
  defaults, so every Dockerfile layer is unchanged — and the root shell
  passes `pkgs.nix` while `app/default.dev.nix` passes `pkgs-app.nix`.
  `app/default.dev.nix` is the shell for UI work: it is the one that
  provides the browser, which is why the flow test skips (naming that
  shell) under the root shell instead of failing.
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


- Dependencies that nothing used are gone: `chromium` (1.3 GB of closure) left
  `nix/system.nix` — the generic layer every future image reuses, which should
  never carry a browser — and `devtools`/`roxygen2` (75 MB) left
  `nix/r-dev.nix`, since `app/` is explicitly not an installed package (no
  `NAMESPACE`, no `man/`) and `api/` has its own `r-api.nix`. Measured:
  `system.nix` 3701 → 2428 MB, `r-dev.nix` 2356 → 2281 MB.
- The shinytest2 flow test now reports why it skipped: `find_chrome()` returns
  `NULL` rather than throwing and `nzchar(NULL)` is `logical(0)`, which
  `skip_if()` silently drops, so the browser check was a no-op and only
  shinytest2's own vaguer error surfaced.
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

- **La paleta de marca deja de estar escrita en seis sitios.** `primary` y
  `primary_dark` (§6.4) pasan a `shared/brand.yaml`: `theme.R`, las tres
  acentos de Leaflet en `mod_setup`/`mod_trip_card`, el gradiente de
  `mod_sensitivity` y el botón CTA del HTML de `share/` llaman a
  `brand_colour()` en vez de repetir `#6d5dfc`. Las curvas hacen lo propio con
  `curve_colours()` en `mod_results`. `strings.R` **no** pierde sus
  `label_curve_*`: ahora son alias de `curve_labels()`, porque §6.2 dice que
  `strings.R` es donde vive el texto de cara al usuario en inglés.
- **`share/R/render_png.R` ya no define `curve_specs()`.** Lo que la tarjeta
  dibuja y lo que Results dibuja salen del mismo fichero, que es el punto
  entero del cambio.

- **Divergences annotated, master document untouched.** §1.3's tree does not
  list `shared/` (it does not list `integration/` or `AGENTS.md` either), and
  the §6.4 snippet still shows the palette literal inline in `theme.R`:
  ```r
  primary = if (modo == "light") "#6d5dfc" else "#8b7dff",
  ```
  The values themselves are unchanged -- the §6.4 palette table remains true
  -- only where the literal lives. Both differences are recorded here rather
  than "fixed" in the master document, which is never edited (precedent: the
  asynchronous create vs §4.6).

- **Nix split so no image ships what it never runs.**
  `nix/r-app.nix` grew a `withDev` argument (default `true`, so the dev shell
  is unchanged): `app/default.prod.nix` builds it with `withDev = false` and
  the UI image therefore has no `testthat`, no `callr` and no `plumber2` --
  the latter only ever served `dev/mock_api.R`, which no deployment ships.
  `testthat` left `nix/r-api.nix` for `api/default.dev.nix`, because
  `r-api.nix` *is* the API image's layer (Dockerfile 9b) and a deployment runs
  no tests. Verified: the API suite still passes at 472 assertions with the
  models and dataset hidden.

- **Section 1.0 says ShinyProxy "does not receive `API_INTERNAL_KEY`", but 8.3
  interpolates `${API_INTERNAL_KEY}` into the containers it creates.** Without
  the value in its environment the injected one comes out empty and every
  request from the UI would 403, so it is read as "ShinyProxy is not an API
  client". Annotated here rather than corrected in the master document.

- **Images are ~4.3-5.3 GB each because `nix/system.nix` carries toolchain a
  runtime never uses**: `openjdk` 572 MB, a source tree 482 MB, `gfortran`
  338 MB, `gcc` 283 MB, `glibc-locales` 222 MB, `python3` 143 MB. §1.1 limits
  RAM, not image size, so nothing is violated -- but a
  `nix/system-runtime.nix` without `nix` and without the compiler would cut
  roughly 2 GB per image and make GHCR pushes much faster. Recorded as a
  follow-up rather than changed here: `system.nix` is the layer every image
  and every shell shares.

- **Six bugs the smoke test found in the phase-7 configuration, all committed
  and all invisible to `nginx -t`, `compose config` and `actionlint`:**
  1. `share` had `env_file: .env`, which hands it `POSTGRES_*` -- section 1.0
     says share never receives database credentials, and 5.10 is built on it
     having none. It now gets an explicit `environment:` list. Caught by the
     §10(e) check.
  2. The API healthcheck sent no `X-Internal-Key`, so it got 403 forever;
     `share` waits on `condition: service_healthy` and Nginx waits on `share`,
     so the whole edge would never have come up. The probe now reads the key
     from the container's own environment -- it never appears in
     `docker inspect`.
  3. `proxy.max-instances: 10` in `application.yml` made the JVM refuse to
     start: Spring expects `Map<String, Integer>`, not an integer. ShinyProxy
     crashed in a loop and the only thing that answered was the 503 page.
     The real bound is `max-total-instances` on the spec, which §8.3 does
     specify; the extra key was mine and is gone.
  4. `shm_size: 2g` against `mem_limit: 1.5g` -- a tmpfs larger than the
     container's own memory. Now 256 MB, twice what `mori`'s 119 MB needs, and
     the margin is not cosmetic: measured on this stack, all four models load
     at RSS 1086 MB with `shm=256m`, while a smaller shm makes the policy fall
     back to the R heap and RSS jumps to 1977 MB -- past the `mem_limit`, so
     the container would be OOM-killed.
  5. The dev container published `2222:22` on `0.0.0.0`, i.e. root SSH on every
     network the host joins. Now `127.0.0.1:2222:22`.
  6. `app_data_dir()` did not know about the mount target §8.3 uses (see
     Added).

- **Failed API calls were silently swallowed: the visitor clicked and nothing
  happened.** A rejected promise reaches `ExtendedTask$result()` as
  `shiny.silent.error` **with an empty message** -- Shiny discards the text on
  the way across -- and `task_result()` re-raised anything of that class to
  wait quietly, so `showNotification` was unreachable dead code for every
  mirai-backed call (all seven of them). `status()` does not help either: a
  failed mirai task still reports `running`.
  `api_async()` now never rejects. It resolves to `list(value = ...)` on
  success and `list(failure = <the API's message>)` on failure, and
  `task_result()` turns the latter into a notification and a `NULL` -- which
  is what all seven callers already expect from a failure. Workers that will
  not start resolve the same way through `promise_resolve`, because that path
  cannot build a mirai. Section 10 asked for this test; the test found the bug.

- **All six compose services are hardened**: `cap_drop: [ALL]` with an explicit
  `cap_add` (nginx needs to bind 80/443 and drop to `nginx`; postgres and
  redis need to chown their data directory; the three images we build need
  nothing), `pids_limit`, `security_opt: no-new-privileges`, and
  `read_only: true` with an explicit `tmpfs` for everything each service
  writes. Nothing was discovered by reading docs: every mount was found by
  making the filesystem read-only and running the smoke test.
- **The three images run as `USER 65534:65534`** with `HOME=/tmp`. The Nix
  base image has no `useradd` and `/etc/passwd` is a symlink into the store,
  so a numeric id is the portable choice; `id` inside the container reports
  `nobody`, and `/health` still answers 200 with RSS unchanged (199 MB for
  share).
- **The API healthcheck is `curl`, not `Rscript`.** It used to start a full R
  interpreter every 30s -- about a second and 100-200 MB -- inside a container
  limited to 1.5 GB. `curl` now lives in `nix/system.nix` rather than in
  `/root/.nix-profile`, which a non-root user cannot traverse, and the probe
  reads `$$API_INTERNAL_KEY` so `docker inspect` shows a variable name and
  never the value.

- **`contract/share.openapi.yaml` gains `POST /render-card`.** Divergence with
  §5.10, which lists `share/`'s routes as `GET /share/{token}`,
  `GET /share/{token}.png`, `POST /waitlist` and `GET /health` (plus the Plan B
  `client-token`). The new route is internal, requires `X-Internal-Key` and is
  unreachable from the Internet: Nginx proxies only `/share/` and `/waitlist`,
  and `share`'s port is `expose:`. Annotated here rather than corrected in the
  master document; see `docs/decisions/0005-push-the-card-payload.md`.

- **`POST /share-email` could never succeed, in any deployment.** plumber2
  serves one request at a time in the R process, and the handler called
  `share` for the card while `share` called back for the data: the callback
  timed out after 10 s (measured: a parallel `GET /health` stalled for
  **10 129 ms** during the E2E run), `share` answered 503, and the API turned
  that into the 503 the visitor saw. The card is now **pushed**: the API
  builds the payload itself through `share_data_payload()` -- the same builder
  `GET /share-data/{token}` uses, so the two cannot drift -- and `share`
  renders it without ever making a callback. The E2E proves it end to end: 200,
  one message in the catcher, one attachment.
- `fetch_share_png()`'s catch swallowed every reason for failing, so the only
  clue was a bare "PNG fetch failed". The replacement logs the transport
  error, the upstream status and the body.

- **The per-request line cannot be built with plumber2's `access_log_format`.**
  That format is a cli/glue template: it substitutes `{...}` and then runs the
  result through cli again, so any value containing a brace -- which every JSON
  object does -- is parsed as an R expression. Three different formats were
  tried and all three killed the server on the first request with
  "Could not parse cli `{}` expression". The logger receives the response and
  the request, so the line is `sprintf`'d in R instead, and the format is left
  as the single token `STATUS={response$status}`, which is also the only place
  the final status is reliably available (`res` and `request$response` were
  both observed to lag: a 404 logged as 200, and a stale 404 on a 200).
  `correlation_id` is formatted from the clock rather than computed with
  `as.numeric(Sys.time()) * 1e6 %% 1e9`: a double does not carry 15+6 digits,
  so consecutive requests collided on the same id.
- Nginx logs `$request_id` and passes it as `X-Request-Id`. **The Shiny app
  does not forward it yet**, so the edge id and the API's `correlation_id` are
  two separate chains today; the header is in place for when it does.

- `disk_check.sh` sent its alert with `curl -H "Subject: ..."`, and curl
  prepends those headers to the upload **without a blank line** -- so the body
  looked like a continuation of the Subject and the server answered
  `451 4.3.5 malformed header line`. The disk alert had never actually been
  deliverable. The whole RFC822 message now goes in the upload instead, and
  `health_check.sh` was written the same way from the start.

- `POST /experiments/{id}/feedback` **without** a `comment` (optional in the
  contract) died inside `db_lit()` -- "expects a scalar" -- and answered
  503 "Database unavailable" for a stored rating. A missing comment is SQL
  NULL; `503` is now documented for that path too, as `/finish` and
  `/abandon` already did.
- `db_finish_experiment()` accepted `trips_accepted` and `trips_rejected` and
  never wrote them, and `001_init.sql` has no such columns at all. So
  `GET /share-data/{token}` returned `null` for two required integers and the
  public card could show no trip counts. They are now derived from the
  player's decisions -- the same source `POST /finish` uses for
  `result$trips_accepted`.
- `Experiment.feedback.comment` is emitted as `null` when there is no
  comment, but the contract declared `type: string`. It is now
  `type: [string, "null"]`, the spelling the contract already uses for
  `finished_at`.
- `integration/test-router-auth.R` still required the header catch-all to
  *be* `internal_auth_header`; section 11 moved it to `request_context`,
  which wraps auth. It now asserts the registration **and** that
  `request_context` performs the internal-key check.

- Two failures that only appear once the code lives in a namespace, both
  found by the suite and both impossible to see before:
  - `data.table::cedta()` silently downgrades `x[i, on = …]` to
    `[.data.frame` for a calling package it does not recognise, and the join
    then dies with "invalid subscript type 'list'". The package now sets
    `.datatable.aware <- TRUE`.
  - `prep.step_join_geospatial_features` stopped being found as soon as it
    left `globalenv()`: S3 dispatch uses what a package declares, not what it
    happens to have attached.
- `test-simulate.R` nested two `local_mocked_bindings()` on the same binding
  in different frames; the inner restore then wrote a binding the outer one
  had already re-locked ("cannot change value of locked binding"). The two
  mocks are siblings now.

- `app/R/constants.R` carried two `§` characters, and `pkgload` reads R files
  through a path that does not accept them: it truncated the file at byte 777,
  so `app_data_dir()`, `load_env_file()` and everything after line 14 silently
  did not exist in the package while the other 15 files loaded fine. It was
  the only R file in the repository with non-ASCII bytes. The comments now say
  "section 8.3".
- Moving `shinytest2` out of `nix/r-shiny.nix` without adding it to
  `app/default.dev.nix`'s `R_LIBS_SITE` made the flow test skip instead of
  fail, which is how the omission was found.

- `covr` was going to measure itself: it runs every `.R` file of `tests/`, so
  a coverage script sitting there would have recursed forever. It lives in
  `dev/` now, and a comment says why.
- `package_coverage()` installed the package but could not run its tests: the
  script resolved `tests/testthat` against whatever directory covr stood in.
  It now resolves against its own location, which is also what a plain
  `Rscript tests/testthat.R` wants.

- **A corrupt `ReferenceDistribution.qs2` was accepted as a reference.**
  `qs2::qs_read()` does not raise on a bad file -- it returns the message
  text as a character vector -- so `reference_distribution()` cached that
  string and `reference_percentile()` would have failed with "invalid $
  operator" the next time `POST /finish` asked for a percentile: a damaged
  file became a 500 on the last screen of the day. It now requires a list
  with `by_company` before caching anything.
- The coverage step had been **silently dropped from CI** when the test jobs
  moved into the development image: the rewrite replaced every job's `steps:`
  block and the coverage step was not among what it kept. Restored, inside
  the same image as the tests.

- **Two colours failed section 12 and are fixed.** `#64748b`, used for
  `.kpi-label` and `.kbd-footer`, reached 4.44:1 on the light surface and
  3.41:1 on the dark one -- both under the 4.5:1 section 12 asks for, and no
  single grey clears both (the light theme needs a darker value, the dark one
  a lighter one). It is now `--taxi-muted-fg`, a per-theme token with
  `#5b6678` / `#9aa4b2`, which clear 5.4:1 and 6.4:1.

### Fixed

- **`app/dev/e2e.sh` computed the repository root one level too high**
  (`cd ../..` from `app/`, i.e. the *parent* of the repository). Only the
  paths that start the API and read `.env` used it, so the bug hid behind an
  already-running API: with nothing answering, the script ran
  `Rscript api/plumber.R` in a directory without `api/`, the API never came
  up and the first CI run of the browser suite died with "the API never
  answered". Now `cd ..`. `infra/scripts/ci_report.sh` learned two things
  from that run: `never answered` is a reason worth annotating, and the
  `127.0.0.1:8093` narinfo errors of an absent loopback cache (ADR-0013) are
  noise that must be filtered, or they are all an annotation shows.
- `httr2::req_perform()` throws on 4xx/5xx by default, so `api_share_data()`
  collapsed every real status into a caught error and the share page answered
  **503 for an unknown token** instead of 404. `api_request()` now sets
  `is_error = ~ FALSE` (single `req_error()` call -- it stores both hooks at
  once) so only transport failures map to 503.

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
