# NYC Taxi Decision Simulator

<!-- badges: start -->
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

Play a full 8-hour shift as an NYC taxi driver and find out whether you can
beat an XGBoost accept/reject policy. You set the starting conditions, accept
or reject each ride as the day unfolds, and finish against two benchmarks: the
model policy and a naive "accept everything" baseline.

This repository is a **monorepo**: one version, one CI/CD pipeline, one
`docker-compose.yml` for every deployable artifact.

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

Every API call carries `X-Internal-Key` (service-to-service auth) and
`X-Client-IP` (hashed rate limiting); experiment endpoints additionally carry
`X-Resume-Code`. The API has no public routes: only `app/` and `share/` call it,
from the private network.

## Services

| Folder     | Artifact                            | Role |
|------------|-------------------------------------|------|
| `contract/`| OpenAPI 3.1 specs                   | Source of truth for both HTTP APIs |
| `api/`     | `ghcr.io/angelfelizr/nyc-taxi-api`  | plumber2: simulation, models, persistence |
| `app/`     | `ghcr.io/angelfelizr/nyc-taxi-shiny`| Shiny UI (thin client, no domain logic) |
| `share/`   | `ghcr.io/angelfelizr/nyc-taxi-share`| Public share pages, PNG, waitlist |
| `infra/`   | (no image)                          | Nginx, ShinyProxy, backups, scripts |
| `tools/`   | (no image)                          | Offline scripts (reference distribution) |
| `integration/` | (no image)                       | R package with API↔UI integration tests |
| `shared/`   | (no image)                          | Visual config (curve spec, brand palette) read by `app/` and `share/` |

## Repository layout

- `contract/openapi.yaml` — private API (18 endpoints, all internal).
- `contract/share.openapi.yaml` — public `share` service (3 routes).
- `app/` — the Shiny app: `app.R`, `R/`, `www/`, `tests/`, `cypress/` and
  `dev/` (the harness that starts the API, share/, the client-IP proxy and
  the app for the browser suite).
- `shared/` — YAML visual config shared by `app/` and `share/`
  (`curves.yaml`, `brand.yaml`), read through `shared/load.R`.
- `nix/` — pinned nixpkgs modules; `default.nix` at the root aggregates them.
- `docs/decisions/` — ADRs · `docs/operations/` — runbook ·
  `docs/REPO_DECISION.md` — monorepo vs. split-repos analysis.
- `04 - Documento Maestro de Decisiones del Proyecto.md` — master decision
  document (Spanish, the source of truth; never edit it).

## Development

R comes from Nix; there is no R outside the pinned environment.

```sh
# Enter the dev container (sshd on host port 2222, repo at /root/NycTaxiApp)
./setup.sh            # or ./setup.sh -np to reuse the local image

# Inside the container
nix-shell                                  # root env (default.nix -A shell)
cd app && Rscript tests/testthat.R         # UI unit tests
./dev/e2e.sh                               # browser suite: real API + share + proxy
```

Secrets live in a single root `.env` (copy `.env.example`); it is gitignored.
Models and datasets are not baked into images: they are downloaded once at
deploy time from the
[`v0.0.1-data` release](https://github.com/AngelFelizR/NycTaxiApp/releases/tag/v0.0.1-data)
and mounted read-only.

## Implementation phases

Tracked in the master document (§14): 0 contract & structure · 1 API base ·
2 sensitivity · 3 persistence & experiments · 4 UI setup · 5 UI trips ·
6 results & share · 7 infra & deploy · 8 load testing · 9 content.

## License

[MIT](LICENSE)
