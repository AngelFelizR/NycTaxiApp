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

### Changed

- The Shiny UI now lives in `app/` (it used to occupy the repo root).
- The project is a thin Shiny client for the plumber2 API; domain logic lives
  in the API.
