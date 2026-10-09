# Topics — where everything lives

A **link-only index**: one entry per topic, pointing at the canonical file
for the *how* and at the ADR / master-document section for the *why*. It
contains no reasoning of its own, so it can never contradict the documents
it points to.

**Rules** (same spirit as `decisions/README.md`):

1. Links only, no prose beyond a label — a claim that needs a paragraph
   belongs in the file it describes.
2. Add or move an entry **in the same commit** as the thing it indexes.
3. If a link here disagrees with its target, this file is what is wrong.

Master document = `../04 - Documento Maestro de Decisiones del Proyecto.md`
(immutable spec, cited as §x).

## Environment and builds (Nix)

- [nix/pkgs.nix](../nix/pkgs.nix) — shared nixpkgs pin
- [nix/pkgs-api.nix](../nix/pkgs-api.nix) — API pin (training environment)
- [nix/pkgs-app.nix](../nix/pkgs-app.nix) — UI pin
- [nix/system.nix](../nix/system.nix) — generic system layer (shells, dev image)
- [nix/system-runtime.nix](../nix/system-runtime.nix) — image layer without `nix` — ADR [0008](decisions/0008-runtime-system-layer.md)
- [nix/r-slim.nix](../nix/r-slim.nix) — R without its build toolchain — ADR [0011](decisions/0011-runtime-r-without-the-toolchain.md)
- [nix/r-api.nix](../nix/r-api.nix) · [nix/r-app.nix](../nix/r-app.nix) · [nix/r-share.nix](../nix/r-share.nix) — runtime package sets per service
- [nix/r-shiny.nix](../nix/r-shiny.nix) · [nix/r-geo.nix](../nix/r-geo.nix) · [nix/r-plotting.nix](../nix/r-plotting.nix) · [nix/r-dev.nix](../nix/r-dev.nix) · [nix/r-shared.nix](../nix/r-shared.nix) — UI/shared/dev modules
- [nix/node.nix](../nix/node.nix) — node for the browser toolchain
- [default.nix](../default.nix) — root shell, auto-discovers `r-*.nix`
- [api/default.dev.nix](../api/default.dev.nix) · [app/default.dev.nix](../app/default.dev.nix) · [share/default.dev.nix](../share/default.dev.nix) — per-service dev shells
- [api/default.prod.nix](../api/default.prod.nix) · [app/default.prod.nix](../app/default.prod.nix) · [share/default.prod.nix](../share/default.prod.nix) — image-build variants
- [infra/scripts/dev-image.sh](../infra/scripts/dev-image.sh) — build/check of the dev image, local binary cache — ADR [0013](decisions/0013-local-nix-binary-cache.md)
- AGENTS § "Nix (§1.2.3 + decisión)" · § "El binario cache local de Nix (ADR-0013)"

## Images, compose and the stack

- [api/Dockerfile](../api/Dockerfile) · [app/Dockerfile](../app/Dockerfile) · [share/Dockerfile](../share/Dockerfile) — multi-stage Nix-closure images
- [Dockerfile](../Dockerfile) — development image (the CI test runner)
- [docker-compose.yml](../docker-compose.yml) — dev stack (Postgres, Redis, mailpit)
- [docker-compose.prod.yml](../docker-compose.prod.yml) — canonical deployment, standalone
- [docker-compose.smoke.yml](../docker-compose.smoke.yml) — smoke overlay (repo-only paths)
- [infra/scripts/smoke-stack.sh](../infra/scripts/smoke-stack.sh) — exposure assertions — ADR [0004](decisions/0004-container-hardening.md)
- [docker-compose healthchecks and hardening](../docker-compose.prod.yml) — caps/read-only/tmpfs per service
- AGENTS § "Fase 7: infra y despliegue" · § "Las imágenes, de verdad" · § "Endurecimiento (ADR-004)"

## CI/CD

- [.github/workflows/ci.yml](../.github/workflows/ci.yml) — the whole pipeline
- [infra/scripts/ci_report.sh](../infra/scripts/ci_report.sh) — log → public annotations
- [infra/scripts/dev-image.sh](../infra/scripts/dev-image.sh) — `check` gate before any test
- ADR [0001](decisions/0001-api-tests-use-fixed-postgres.md) — service containers, not testcontainers
- AGENTS § "Contenedor de desarrollo" · docs/PLANS § "How the CI jobs got green"

## Testing

- [api/tests/](../api/tests/testthat/) — API suite (handlers, DB, async, coverage)
- [app/tests/](../app/tests/testthat/) — UI units (state, privacy, accessibility, client)
- [share/tests/](../share/tests/testthat/) — share service suite
- [integration/tests/](../integration/tests/testthat/) — the three descriptions of the system
- [app/cypress/](../app/cypress/e2e/) — browser specs against the real stack
- [app/dev/e2e.sh](../app/dev/e2e.sh) · [app/dev/e2e-proxy.js](../app/dev/e2e-proxy.js) — orchestrator and client-IP proxy
- [app/dev/load_test.sh](../app/dev/load_test.sh) — load harness (N sessions, §8 numbers) — ADR [0012](decisions/0012-cypress-is-the-e2e-and-load-tool.md)
- [app/cypress/load/load.cy.js](../app/cypress/load/load.cy.js) — one load session (own day, own strategy, own results)
- [app/dev/load_sessions.js](../app/dev/load_sessions.js) · [load_sessions.selftest.sh](../app/dev/load_sessions.selftest.sh) — cross-session analyzer and its smoke
- [app/dev/median_day.R](../app/dev/median_day.R) — the median day from SQL
- [app/cypress/redis_client.js](../app/cypress/redis_client.js) — RESP by hand (Cypress tasks + harness FLUSHDB)
- [api/dev/coverage.R](../api/dev/coverage.R) — §10 coverage, both thresholds
- [api/dev/smoke.sh](../api/dev/smoke.sh) · [api/dev/e2e_experiments.sh](../api/dev/e2e_experiments.sh) — HTTP smoke and experiment E2E
- ADRs [0006](decisions/0006-response-schema-conformance.md), [0007](decisions/0007-both-services-are-packages.md), [0012](decisions/0012-cypress-is-the-e2e-and-load-tool.md), [0014](decisions/0014-the-ui-tests-the-real-api.md)
- AGENTS § "Tests: cuatro paquetes de R separados"

## Contracts and HTTP surface

- [contract/openapi.yaml](../contract/openapi.yaml) — private API (authoritative)
- [contract/share.openapi.yaml](../contract/share.openapi.yaml) — public share service
- [contract/.spectral.yaml](../contract/.spectral.yaml) — Spectral ruleset (`oas3-schema: warn`)
- [api/tests/testthat/helper-contract.R](../api/tests/testthat/helper-contract.R) — ajv conformance helper — ADR [0006](decisions/0006-response-schema-conformance.md)
- [integration/tests/testthat/test-contract-api.R](../integration/tests/testthat/test-contract-api.R) · [test-contract-clients.R](../integration/tests/testthat/test-contract-clients.R) — routes/clients vs contract
- AGENTS § "Contratos OpenAPI (`contract/`)" · § "Fuente de verdad"

## The API (plumber2)

- [api/plumber.R](../api/plumber.R) — entry point (middleware order, OMP warning, warmup)
- [api/R/middleware_request_context.R](../api/R/middleware_request_context.R) — §11 log + auth wrap
- [api/R/middleware_internal_auth.R](../api/R/middleware_internal_auth.R) · [middleware_client_ip.R](../api/R/middleware_client_ip.R) · [middleware_rate_limit.R](../api/R/middleware_rate_limit.R) — auth chain, IP, limits
- [api/R/endpoint_experiments.R](../api/R/endpoint_experiments.R) — async create, decisions, finish
- [api/R/ml_simulate.R](../api/R/ml_simulate.R) · [ml_outcome.R](../api/R/ml_outcome.R) · [ml_sensitivity.R](../api/R/ml_sensitivity.R) — simulation, outcome, sensitivity
- [api/migrations/](../api/migrations/) — idempotent schema
- ADRs [0002](decisions/0002-sensitivity-redis-cache.md), [0005](decisions/0005-push-the-card-payload.md), [0009](decisions/0009-setup-progress-on-the-row.md)
- AGENTS § "Cómo habla la UI con la API" · § "Experimentos (fase 3)"

## The Shiny app

- [app/app.R](../app/app.R) — shell (navbar, module wiring)
- [app/R/state.R](../app/R/state.R) — per-session `estado`
- [app/R/api_client.R](../app/R/api_client.R) — the only file that knows routes
- [app/R/utils.R](../app/R/utils.R) — `task_result()`, daemons, env
- [app/R/_disable_autoload.R](../app/R/_disable_autoload.R) — do not rename (load-order marker)
- [app/R/shared_config.R](../app/R/shared_config.R) — bridges `shared/` into `R/` (must sort before `strings.R`)
- [app/R/strings.R](../app/R/strings.R) — every user-facing string
- [app/R/mod_trips.R](../app/R/mod_trips.R) · [mod_results.R](../app/R/mod_results.R) · [mod_setup.R](../app/R/mod_setup.R) — screens
- ADR [0003](decisions/0003-shared-visual-config.md) (shared config)
- AGENTS § "La UI vive en `app/`" · § "`mod_share`" · § "Cómo arrancar la app a mano"

## The public share service

- [share/plumber.R](../share/plumber.R) — entry point
- [share/R/routes.R](../share/R/routes.R) — handlers + `share_api()` builder
- [share/R/render_png.R](../share/R/render_png.R) · [render_html.R](../share/R/render_html.R) — card and page
- [share/R/cache.R](../share/R/cache.R) · [bots.R](../share/R/bots.R) — views counter, crawler filter
- ADRs [0005](decisions/0005-push-the-card-payload.md) (push render), [0010](decisions/0010-one-cache-layer-for-the-card.md) (edge-only cache)
- AGENTS § "El servicio público `share/`"

## Shared visual config

- [shared/curves.yaml](../shared/curves.yaml) · [shared/brand.yaml](../shared/brand.yaml) — the spec
- [shared/load.R](../shared/load.R) — loader + exported validators
- ADR [0003](decisions/0003-shared-visual-config.md) — why YAML, why exported validators
- AGENTS § "`shared/` — la configuración visual compartida"

## Infrastructure and operations

- [infra/nginx/nginx.conf](../infra/nginx/nginx.conf) — edge routing, headers, 503 page
- [infra/nginx/snippets/](../infra/nginx/snippets/) · [infra/nginx/html/](../infra/nginx/html/) — security headers, capacity page
- [infra/shinyproxy/application.yml](../infra/shinyproxy/application.yml) — session containers, §8.3
- [infra/scripts/backup.sh](../infra/scripts/backup.sh) · [restore_test.sh](../infra/scripts/restore_test.sh) · [disk_check.sh](../infra/scripts/disk_check.sh) · [health_check.sh](../infra/scripts/health_check.sh) — data safety and alerts
- [docs/operations/runbook.md](operations/runbook.md) — incidents (incl. §8 capacity ceiling)
- [docs/operations/first-deploy.md](operations/first-deploy.md) — everything outside the repo
- [README.md](../README.md) — the load-test numbers (phase 8)
- ADR [0004](decisions/0004-container-hardening.md)
- AGENTS § "Fase 7" · § "Monitor de servicios"

## Security and privacy

- [app/www/privacy.html](../app/www/privacy.html) — §9.1 notice (test-enforced)
- [api/R/middleware_internal_auth.R](../api/R/middleware_internal_auth.R) — `X-Internal-Key` / `X-Resume-Code`
- [api/R/middleware_cors.R](../api/R/middleware_cors.R) — origin rules
- [.env.example](../.env.example) — every variable, scan-tested in CI
- ADR [0004](decisions/0004-container-hardening.md)
- Master document §9 · AGENTS § "Red y seguridad" · runbook § PII erasure

## Data and models

- [tools/build_reference_distribution.R](../tools/build_reference_distribution.R) — offline reference build
- [infra/scripts/fetch-assets.sh](../infra/scripts/fetch-assets.sh) — verified release download (deploy gate)
- [infra/scripts/make-manifest.sh](../infra/scripts/make-manifest.sh) · [test-fetch-assets.sh](../infra/scripts/test-fetch-assets.sh) — manifest and its hermetic test
- Master document §4.5, §15 (the six assets, release `v0.0.1-data`)

## Decisions, plans and conventions

- [docs/decisions/README.md](decisions/README.md) — taxonomy: where a decision goes
- [docs/decisions/_template.md](decisions/_template.md) — ADR template (Alternatives mandatory)
- [docs/decisions/](decisions/) — ADRs 0001–0014
- [CHANGELOG.md](../CHANGELOG.md) — history + divergences from the master document
- [docs/REPO_DECISION.md](REPO_DECISION.md) — monorepo vs split, split triggers
- [docs/PLANS.md](PLANS.md) — living roadmap (not a decision record)
- [AGENTS.md](../AGENTS.md) — how to work in this repo
- [README.md](../README.md) — system narrative
