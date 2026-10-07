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

### Changed

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

### Fixed

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
