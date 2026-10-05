# 0001. API tests use the fixed Postgres from the root compose

- Status: Accepted
- Date: 2026-10-05
- Phase: 1 (API base)

## Context

The master document (`04 - Documento Maestro de Decisiones del Proyecto.md`,
§8 "test-api" and the phase list) states that the API test suite runs with
`testcontainers` and an ephemeral Postgres per suite. While building the
phase-1 test package (`api/tests/`), running real database tests through
testcontainers was weighed against reusing the Postgres service that already
ships in the root `docker-compose.yml` (the same one the API uses in
development: `POSTGRES_HOST=postgres`, credentials from `.env`).

## Decision

The API test suites use the **fixed Postgres service from the root
`docker-compose.yml`** instead of an ephemeral testcontainers instance.

Consequences:

- Tests that need a database expect `docker compose up -d postgres` (already
  part of the development flow) and read the same `.env` variables as the API.
- No Docker-in-Docker / testcontainers dependency in the Nix shells or CI; the
  CI job for `api/` provides a `postgres` service container instead.
- Pure unit tests (everything in `api/tests/testthat/` today) do not touch the
  database at all; the pool branch of `/health` is covered by the HTTP smoke
  script (`api/dev/smoke.sh`) against the running stack.
- This diverges from the master document on this single point. Per the repo
  rule, the document keeps the original wording (testcontainers) as the
  reference; this ADR records the agreed replacement. Update the document only
  through its own change process.

## Related note: hvfhs example in the contract

`contract/openapi.yaml` (description of `hvfhs_license_num`) uses
`HV0002` as the Lyft example, while the real TLC license numbers implemented
in `api/R/utils.R` (`company_to_hvfhs()`) are `HV0003` (Uber) and `HV0005`
(Lyft), which is what the training data uses. The code follows the data; the
contract wording is an example only (`e.g.`) and does not constrain the
feature value. No contract change is required, but any future schema tightening
must use `HV0005`.
