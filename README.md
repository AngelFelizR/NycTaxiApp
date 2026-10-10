# NYC Taxi Decision Simulator

<!-- badges: start -->
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![CI](https://github.com/AngelFelizR/NycTaxiApp/actions/workflows/ci.yml/badge.svg)](https://github.com/AngelFelizR/NycTaxiApp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
<!-- badges: end -->

Play a full 8-hour shift as an NYC taxi driver and find out whether you can
beat an XGBoost accept/reject policy. You set the starting conditions,
accept or reject each ride as the day unfolds, and finish against two
benchmarks: the **model policy** and a naive **"accept everything"**
baseline.

This repository is a **monorepo**: one version, one CI/CD pipeline, one
`docker-compose.yml` for every deployable artifact — a contract-first
plumber2 API, a Shiny UI, and a minimal public share service, all in R,
all tested.

## Contents

- [What you play](#what-you-play)
- [The machine learning behind it](#the-machine-learning-behind-it)
- [Quick start](#quick-start)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Tech stack](#tech-stack)
- [Design decisions](#design-decisions)
- [Testing and quality](#testing-and-quality)
- [Performance and capacity](#performance-and-capacity)
- [CI/CD](#cicd)
- [Security and privacy](#security-and-privacy)
- [Operations](#operations)
- [Status](#status)
- [References](#references)

---

## What you play

One session = one simulated working day: 8 hours plus a 30-minute tail,
trip offers arriving on the fly, and a clock you can pause and resume.
Every decision is scored against the two benchmarks above, and the day
ends with six KPIs, three cumulative curves, and your **percentile among
1,000 simulated model days**.

The whole game is a thin client. The browser owns no domain logic: it
sends clicks, the server simulates, decides the outcome, and computes the
percentile (§4.6 — *"siempre en el servidor"*). A session can be left
mid-day and resumed from a code.

---

## The machine learning behind it

| Piece | What it is | Where |
|---|---|---|
| **Accept/reject policy** | Fitted XGBoost workflow served as the "model benchmark" you play against | `AcceptRejectPolicyFitted.qs2` (release asset) |
| **Start-time validator** | Predicts the valid hours to start working from a zone/company (Setup validation) | `ValidHoursToStartWorking.qs2` |
| **Interpretable twin** | A fitted decision tree used to explain individual offers ("why the model says reject") | `DecisionTreeWfFitted.qs2` |
| **Reference distribution** | 1,000 simulated days per company, built offline, turns your raw score into a percentile | `ReferenceDistribution.qs2`, built by `tools/build_reference_distribution.R` (~75 min) |
| **Sensitivity grid** | 50×50 (30×30 on mobile) "which zone would flip this decision" boundary, recomputed per day and cached in Redis | `POST /sensitivity`, `api/R/ml_sensitivity.R` |

How it is served, in one paragraph: models are **never baked into images
or git** — they are downloaded once from the
[`v0.0.1-data` release](https://github.com/AngelFelizR/NycTaxiApp/releases/tag/v0.0.1-data)
with SHA-256 verification (`infra/scripts/fetch-assets.sh`, §4.5) and
mounted read-only. The API loads them **once at boot** with `qs2` and
publishes them zero-copy with `mori::share()` into `/dev/shm`, so every
mirai worker scores against the same in-memory copy. Training happens in
the prototype repository ([`~/r-projects/NycTaxi`](https://github.com/AngelFelizR/NycTaxi));
this repo serves, evaluates and simulates — never trains.

The dataset is one week of TLC trip records: **4,867,180 rows across 263
zones**, loaded from Parquet in ~4.5 s / 334 MB at API startup.

---

## Quick start

### Prerequisites

- **Docker + Compose v2** (the only host dependency for running it)
- An SSH key at `~/.ssh/id_ed25519.pub` (the dev container installs it)
- ~10 GB of disk for the dev path: the dev image (~9 GB, pulled from
  GHCR) + the release assets (~534 MB). The three production images
  (~14 GB) are only needed to run `smoke-stack.sh` locally. Everything
  comes from `ghcr.io/angelfelizr/*` — see
  [ADR-0015](docs/decisions/0015-mirror-third-party-images-into-ghcr.md).
- Optional, for contract linting only: Docker is enough — Spectral runs
  in a container, there is no Node on the host

### One-time setup

```sh
git clone git@github.com:AngelFelizR/NycTaxiApp.git && cd NycTaxiApp
cp .env.example .env
# Edit .env — the four values that are yours to invent:
#   POSTGRES_PASSWORD, API_INTERNAL_KEY, IP_HASH_SALT   (any random strings)
#   MODELS_DIR=~/nyctaxi/models, DATA_DIR=~/nyctaxi/data

# Download + SHA-256-verify the models and dataset (§4.5). Aborts without
# touching anything if a checksum does not match.
MODELS_DIR=~/nyctaxi/models DATA_DIR=~/nyctaxi/data \
  ./infra/scripts/fetch-assets.sh

./setup.sh    # pulls the dev image, starts the stack, installs your SSH key
              # (add -np once you have the image locally, to skip the pull)
ssh NycTaxi   # you are now in the dev container, repo at /root/NycTaxiApp
```

Everything below runs **inside that container** (`ssh NycTaxi`), where
Postgres, Redis and mailpit already resolve by name. `.env` is read from
the repo root; the container overrides only what development needs
(`TAXI_API_URL=http://127.0.0.1:8000`, the local SMTP catcher) — see the
comments in `docker-compose.yml`.

### Run the app

One command, no SSH, no terminals:

```sh
docker compose -f docker-compose.test.yml up -d
# then open http://127.0.0.1:3838
```

That starts **the images production runs**, Postgres, Redis, mailpit and an
edge, in the order compose's health checks dictate. The edge is not
decoration: it injects `X-Client-IP` (the API allows 3 experiments per IP per
day and would otherwise count every request as the same one) and serves the
app and `share/` from a single origin, the way Nginx does in production. Dev
emails land in **mailpit at <http://127.0.0.1:18025>**. Tear it down with
`docker compose -f docker-compose.test.yml down`.

First time on a fresh checkout the three images are not there yet, so use
`up -d --build` once (the Dockerfiles build Nix from the pins; later runs are
cached). The default tag is **`test`**, the one a workstation builds, because
CI publishes `:latest` as **arm64 only** — the deployment VM is ARM — and it
will not pull on an x86_64 laptop. On ARM, `NYCTAXI_TAG=latest docker compose
-f docker-compose.test.yml up -d`.

It needs the release assets in the directories `.env` points at — that is what
the one-time setup above downloads. It does **not** run ShinyProxy or TLS: the
deployed topology is `infra/scripts/smoke-stack.sh`'s job, and this file's job
is to let you play a day.

### Develop (the dev container)

To change the code you want the repo mounted and a real Nix shell, which is
what `./setup.sh` gives you. Three services, three terminals — the API must be
up before the UI:

```sh
# Terminal 1 — the API (private, :8000)
ssh NycTaxi
cd /root/NycTaxiApp && nix-shell api/default.dev.nix --run "Rscript api/plumber.R"

# Terminal 2 — the UI (:3838)
ssh NycTaxi
cd /root/NycTaxiApp/app && nix-shell default.dev.nix --run \
  'Rscript -e "shiny::runApp(\".\", port = 3838)"'

# Terminal 3 (optional) — share/ (:8020), for the share pages and emails
ssh NycTaxi
cd /root/NycTaxiApp && nix-shell share/default.dev.nix --run "Rscript share/plumber.R"
```

The container publishes only SSH, so forward the UI port once and keep the
tunnel open:

```sh
ssh -N -L 3838:127.0.0.1:3838 NycTaxi     # then open http://127.0.0.1:3838
```

Here the emails land in **mailpit at <http://127.0.0.1:8025>** (the test stack
uses 18025, so both can run at once). The UI should print `Listening on ...`
in under 3 seconds; a slower start means something is wrong (see
`AGENTS.md` → *Cómo arrancar la app a mano*).

### Run the tests

```sh
# The four R suites (all inside the container):
cd /root/NycTaxiApp/api         && nix-shell default.dev.nix --run "Rscript tests/testthat.R"
cd /root/NycTaxiApp/app         && nix-shell default.dev.nix --run "Rscript tests/testthat.R"
cd /root/NycTaxiApp/share       && nix-shell default.dev.nix --run "Rscript tests/testthat.R"
cd /root/NycTaxiApp/integration && nix-shell default.dev.nix --run "Rscript tests/testthat.R"

# The browser suite — starts its own API, share/, client-IP proxy and app,
# drives them through Cypress, tears everything down:
cd /root/NycTaxiApp/app && nix-shell default.dev.nix --run ./dev/e2e.sh

# The load test (N concurrent real sessions, own IP, own strategy):
cd /root/NycTaxiApp/app && nix-shell default.dev.nix --run "./dev/load_test.sh 1 10"
```

### Lint the contracts (host, no Node needed)

```sh
docker run --rm -v "$PWD:/repo" -w /repo stoplight/spectral lint \
  contract/openapi.yaml contract/share.openapi.yaml \
  --ruleset contract/.spectral.yaml        # criterion: 0 errors
```

---

## Architecture

```
Internet
   │
   ▼
[Cloudflare CDN] ─── TLS edge + cache for /share/*.png
   │
   ▼
[Nginx :80/:443] ─── only public entry point
   ├─ /          → [ShinyProxy] → ephemeral Shiny containers (max 10)
   ├─ /share/*   → [share :8001]  (HTML + PNG, no database access)
   ├─ /waitlist  → [share :8001]
   └─ /api/*     → 404            (the API is never public)

Private Docker networks:
  nyctaxi_edge_net : nginx, shinyproxy, share
  nyctaxi_api_net  : shinyproxy, shiny-app, share, api   ← only path to the API
  nyctaxi_data_net : api, share, postgres, redis         ← Shiny never reaches data
```

A request that matters, end to end: the browser clicks **Accept** →
Shiny's module calls `POST /decisions` through **httr2 inside a mirai
daemon** (the R process never blocks) → plumber2 validates the session
with `X-Internal-Key` + `X-Resume-Code`, writes one row to Postgres,
and answers → the `ExtendedTask` lands on the UI thread and the clock
moves. When the shift ends, only `POST /finish` computes `outcome` and
`user_percentile` against the reference distribution.

Every API call carries `X-Internal-Key` (service-to-service auth) and
`X-Client-IP` (hashed rate limiting); experiment endpoints additionally
carry `X-Resume-Code`. Only `app/` and `share/` call the API — from the
private network, never from the Internet.

---

## Repository layout

```
NycTaxiApp/
├── contract/          OpenAPI 3.1 specs — the source of truth for both
│                      HTTP APIs (+ Spectral ruleset, validated in CI)
├── api/               plumber2 service: simulation, models, persistence
│   ├── R/             handlers, ML loading, simulation, outcome (package)
│   ├── tests/         testthat: handlers, DB, contract conformance, coverage
│   ├── migrations/    SQL schema for participants/experiments/decisions
│   ├── dev/           coverage.R, smoke.sh, e2e_experiments.sh
│   └── Dockerfile · default.dev.nix · default.prod.nix
├── app/               the Shiny UI (package: app.R + R/ + www/)
│   ├── cypress/       browser specs: e2e/ against the real stack, load/
│   ├── tests/         testthat: state, accessibility, privacy, client
│   └── dev/           e2e.sh, load_test.sh, pa11y.json, median_day.R
├── share/             public service: share pages, PNG card, waitlist
│                      (holds NO database credentials — by design)
├── shared/            visual config both frontends read
│                      (curves.yaml, brand.yaml via shared/load.R)
├── infra/             nginx, shinyproxy, scripts: backup, restore_test,
│                      disk_check, health_check, fetch-assets, smoke-stack
├── nix/               pinned nixpkgs modules; root default.nix aggregates
├── tools/             offline scripts (build_reference_distribution.R)
├── integration/       R package: the three descriptions of the system
│                      (contract ↔ registered routes ↔ client paths)
├── docs/
│   ├── decisions/     ADRs — why each non-obvious decision was made
│   ├── operations/    runbook.md, first-deploy.md
│   └── PLANS.md       living roadmap: what is next and why
├── .github/workflows/ CI: contract lint, four test suites, three image
│                      builds, deploy (path-filtered per service)
│                      + mirror-images.yml (the third-party images, → GHCR)
├── docker-compose.yml / docker-compose.prod.yml / docker-compose.test.yml
├── .env.example       every variable, scan-tested in CI
└── AGENTS.md · CHANGELOG.md · README.md
```

---

## Tech stack

| Layer | Choice | Why this one |
|---|---|---|
| Language | **R** (4.5.2 API pin, 4.6.1 UI pin) | One language across API, UI and tests; the API pin *is* the environment the models were trained in, so serving cannot drift from training |
| HTTP API | **plumber2** | Code-first routers over package functions; no framework lock-in, and the contract in `contract/` stays authoritative |
| UI | **Shiny + bslib** (Bootstrap 5) | Server-driven UI on the same R runtime — no second language for a two-person-scale product; bslib gives theming and the dark-mode toggle for free |
| Non-blocking UI | **httr2 + mirai daemons + `ExtendedTask`** | Every HTTP call runs off the main R process; buttons bind to task state, so the browser session never freezes while the API answers |
| Model I/O | **qs2 + mori** | Compact serialisation on disk, zero-copy sharing in `/dev/shm` between daemons — one copy of a 345 MB policy, not one per worker |
| Database | **PostgreSQL + pool** (RPostgres) | Transactions and one row per finished day as the source of truth; `pg_dump` backups with a restore test |
| Cache & limits | **Redis** | TTL caches (sensitivity grid, share cards, rate limits) that all **fail open**: a Redis outage degrades speed, never correctness |
| Maps & charts | **leaflet + ggiraph** | Interactive zone picking and SVG charts that render client-side, keeping the R process free |
| Contracts | **OpenAPI 3.1 + Spectral + ajv** | Lint the design in CI; validate every response body against it (ADR-0006 — it caught four real defects on its first run) |
| Environment | **Nix** + multi-stage **Docker** | Reproducible R everywhere (no "works on my machine"); images copy a Nix closure instead of apt-installing a toolchain |
| CI/CD | **GitHub Actions**, path-filtered | Only the service you touched pays for its jobs; images push to GHCR |
| Edge (prod) | **Nginx + ShinyProxy + Cloudflare** | One public entry point, ephemeral Shiny containers (max 10), CDN cache for the share PNGs |
| Dev SMTP | **mailpit** | Real SMTP flow in dev with a web inbox — the email features are tested, not stubbed |

---

## Design decisions

Each row is a trade-off that was made **on purpose**; the *Record* column
points at where the reasoning lives (ADRs in `docs/decisions/`,
divergences from the master document in `CHANGELOG.md`).

| Decision | Why | Record |
|---|---|---|
| **One monorepo**, not a repo per service | One version, one pipeline, one compose; the triggers for splitting it are written down so the decision can be revisited with data, not vibes | `docs/REPO_DECISION.md` |
| **Contract first**: both HTTP surfaces live in `contract/` as OpenAPI 3.1 | The contract is executable documentation: Spectral lints it and ajv validates real responses against it, so drift fails CI instead of review | ADR-0006, `integration/` |
| **Both services are R packages** | Flat `R/`, `R CMD INSTALL` in the image, `pkgload::load_all()` in dev — production and tests load the same code, the same way | ADR-0007 |
| **The UI never blocks; the API may queue** | HTTP runs in mirai daemons and lands back via `ExtendedTask`; the single-threaded API is a *measured* property — under load its queue is the latency, so the client timeout and the recovery poll are sized against that measurement, not a guess | `AGENTS.md` → *Cómo habla la UI con la API*, load numbers below |
| **Async create, server-side outcome** | `POST /experiments` answers 201 in ~0.2 s and forks the trajectories; only `POST /finish` computes `outcome` + `user_percentile`. The browser never owns game math | §4.6 (annotated divergence in `CHANGELOG.md`) |
| **Models are verified release assets**, never in git or images | `fetch-assets.sh` aborts before writing if a SHA-256 mismatches — a half-written 345 MB policy that loads and serves garbage is worse than not starting | §4.5, §15 |
| **Two Nix pins** | The API pin is the training environment (R 4.5.2); the UI pin can move independently. Changing one pin rebuilds only that service's layers | `AGENTS.md` → *Nix* |
| **Browser tests hit the real stack; the mock is deleted** | The mock's canned datetime disagreed with the real API and would have approved a broken scenario — a mock can only be as correct as the day it was written | ADR-0014 (supersedes half of ADR-0012) |
| **A fixed Postgres, not testcontainers** | One database definition for dev, CI and tests; a container-per-suite matched production less and cost minutes | ADR-0001 |
| **Third-party images are mirrored, not authenticated** | The service containers are pulled as *step 1* of a job, before `docker/login-action` is step 3 — so a Docker Hub token could never have reached them, and the fix had to be "stop depending on Docker Hub" | ADR-0015 |
| **One cache layer for the share card: the edge** | The Redis PNG cache's counters had read zero since the day they were added — a layer nobody's metrics can see is a layer to remove, not to repair | ADR-0010 |
| **Hardened containers** | `cap_drop: ALL`, read-only rootfs, no new privileges, uid 65534, CSP on the static pages — with the one accepted risk (`docker.sock` in ShinyProxy) documented instead of hidden | ADR-0004 |
| **Load tests and pa11y run locally, not in CI** | CI has no models and no dataset: a p95 measured there would be a number about the stand-in. The runs and their numbers live in the runbook | `CHANGELOG.md` §10 divergence, runbook |

---

## Testing and quality

Six layers, from cheapest to scariest. Every command is in
[`AGENTS.md`](AGENTS.md); the first four run in CI on every push — load
and accessibility stay local because CI has no models and no dataset.

| Layer | What it proves | Where |
|---|---|---|
| **R unit suites** (4 packages) | Handlers, DB writes, state machine, accessibility rules, privacy notice, the contract ↔ router ↔ client triangle | `api/tests/`, `app/tests/`, `share/tests/`, `integration/tests/` |
| **Contract conformance** | Every response body validates against `openapi.yaml` with ajv; every route is documented and vice versa | `api/tests/testthat/helper-contract.R` (ADR-0006) |
| **Coverage gates** | `COVERAGE_FAIL_UNDER=60` globally and `COVERAGE_FAIL_CRITICAL=1` (100 % on seven critical files: auth, client IP, outcome, migrations, sensitivity, simulate) — both enforced in CI, current global ≈ 80 % | `api/dev/coverage.R` |
| **Browser suite** | 4 specs / 5 tests driving the **real** API, share/ and a proxy that carries `X-Client-IP`: full day, the real 429, resume, results | `app/cypress/e2e/` |
| **Load test** | N concurrent real sessions, each with its own IP and strategy; asserts N separate days and reports the server numbers below | `app/dev/load_test.sh` |
| **Accessibility** | pa11y (0 errors), a scripted 390 px mobile checklist (≥44 px targets, touch-hidden hints), and a WebAIM contrast sign-off — all manual by §10, all with recorded procedure | runbook → *Manual checks* |

---

## Performance and capacity

Measured on the development host (8 cores / 16 GB) with profiles 1 and 10,
both strategies, after the fixes the run itself forced:

| | 1 user | 10 users |
|---|---|---|
| Sessions that finished their day | 1/1 | **10/10** (10 distinct experiments) |
| Median day (SQL) | 110 s | 4281 s — above the ≤ 12 min target |
| p95 `/sensitivity` | 1.98 s | 19.6 s |
| Peak RSS (app · api) | 483 · 1143 MB | 575 · 1143 MB |
| Host `MemAvailable`, minimum | 11.8 GB | **1978 MB** |

**Ten users is the ceiling; twelve are not.** §1.1 allows raising
`max-total-instances` to 12 only with ≥ 2 GB of headroom *and* acceptable
latency — neither holds at 10, and the measured memory floor here is
*pessimistic* because this host also runs the ten Chromiums production
does not (the latency is not optimistic). The lever if the queue ever has
to shrink is more API processes behind one address, not a bigger
`max-total-instances`. Details and the incident log: runbook →
*Capacity*.

The load harness also forced four real fixes out of the product (15 s →
45 s client timeout, the recovery poll, a retry faster than the endpoint
it retried, orphaned processes between profiles) — each with its lesson
in `CHANGELOG.md`.

---

## CI/CD

`.github/workflows/ci.yml`, filtered by `paths:` per service:

| Job | What it does |
|---|---|
| `test-contract` | Spectral lint of both OpenAPI documents (10 s, always) |
| `test-api` | testthat inside the dev image with real Postgres + Redis service containers, incl. the coverage gates |
| `test-shiny` | UI units + the browser suite against the real stack, with release assets verified by `fetch-assets.sh` |
| `test-share` | share service suite (PNG, HTML, waitlist, bots) |
| `test-integration` | the contract ↔ routes ↔ clients triangle |
| `build-api` / `build-shiny` / `build-share` | multi-stage Nix images → GHCR, behind the tests |
| `mirror-images` | copies the six third-party images (Postgres, Redis, mailpit, Spectral, alpine, nginx) into `ghcr.io/angelfelizr/*` — weekly and on demand. Nothing in the pipeline pulls from Docker Hub any more; a Docker Hub token could never have fixed the red run, because the service containers are pulled before any step can log in ([ADR-0015](docs/decisions/0015-mirror-third-party-images-into-ghcr.md)) |
| `deploy` | pull on the VM, `fetch-assets`, bring the stack up, smoke test — runs once `VM_HOST`, `VM_USER`, `VM_SSH_KEY` secrets exist (see [`docs/operations/first-deploy.md`](docs/operations/first-deploy.md)) |

Tests run **inside the development image** (`ghcr.io/angelfelizr/nyc-taxi-dev`),
built and pushed by hand with `./infra/scripts/dev-image.sh build` —
building it in CI cost 100 minutes once; the runner only pulls. The
image's local Nix binary cache took a full rebuild from ~54 minutes to
~5 (ADR-0013).

---

## Security and privacy

- **The API has no public routes.** It does not publish a port; Nginx
  answers `/api/*` with 404. The only path to it is the private Docker
  network shared by `app/`, `share/` and `api`.
- **Service auth** is `X-Internal-Key` on every call (403 without it);
  experiment endpoints add `X-Resume-Code`, so a stolen IP alone cannot
  resume someone else's day.
- **Rate limiting** is 3 experiments per IP per day, keyed by
  `sha256(IP_HASH_SALT || ip)` — the hash, never the address, is what
  gets logged (section 11's structured log has `ip_hash`, not `ip`).
- **Containers** run as uid 65534 with all capabilities dropped, a
  read-only rootfs and `no-new-privileges`; the images carry no compiler
  and no model files.
- **Privacy (§9.1)**: email is double opt-in (result card and marketing
  are separate consents, both off by default), a privacy notice is linked
  from Setup, the footer and the email form, and a person's data can be
  erased on request — the procedure is in the runbook.

---

## Operations

Everything that happens *after* deploy lives in
[`docs/operations/`](docs/operations/):

- **[`runbook.md`](docs/operations/runbook.md)** — incidents (disk full,
  PII erasure, key rotation, dead API, share 503, the capacity finding),
  the manual checks (pa11y, WebAIM, mobile), and routine checks.
- **[`first-deploy.md`](docs/operations/first-deploy.md)** — the checklist
  of everything that cannot be done from inside this repository: VM, DNS,
  SMTP credentials, GitHub secrets, Cloudflare, the monitor.
- **Cron scripts** (installed on the VM): `backup.sh` (daily `pg_dump` +
  sha256, 28-day retention), `disk_check.sh` (hourly, alerts ≥ 80 % and
  detects a broken backup schedule), `health_check.sh` (hourly: API,
  share, Postgres, Redis — mail on failure with a 6 h cooldown).
- **`./infra/scripts/smoke-stack.sh`** — lifts the production stack
  locally and asserts what a config file cannot: only 80/443 published,
  the API unreachable from outside, the 503 → capacity page, the CSP.

---

## Status

Master document §14 tracks the phases. Done: **0–8** (contract · API ·
sensitivity · persistence · UI · share · infra · load testing &
hardening). Next: **9 — content & publication** (demo recording, the
Quarto article, announcement).

What is deliberately *not* in this repository: the first deployment's
external steps (VM, DNS, SMTP, GitHub secrets) are checklist items with
verification steps in [`first-deploy.md`](docs/operations/first-deploy.md);
the living roadmap of what is next is [`docs/PLANS.md`](docs/PLANS.md).

---

## References

- **[`04 - Documento Maestro de Decisiones del Proyecto.md`](04%20-%20Documento%20Maestro%20de%20Decisiones%20del%20Proyecto.md)** — the immutable master document (Spanish): architecture, sections, phase prompts. Never edited; where code diverges, the divergence is recorded in [`CHANGELOG.md`](CHANGELOG.md).
- **[`docs/decisions/`](docs/decisions/)** — ADRs: the *why* behind every non-obvious decision, with alternatives considered.
- **[`AGENTS.md`](AGENTS.md)** — how to work in this repo: every command, every convention, every gotcha already paid for.
- **[`docs/PLANS.md`](docs/PLANS.md)** — the living roadmap: what is next and why.
- **[`contract/openapi.yaml`](contract/openapi.yaml)** — the authoritative HTTP surface (18 private endpoints) of the API.

## License

[MIT](LICENSE)
