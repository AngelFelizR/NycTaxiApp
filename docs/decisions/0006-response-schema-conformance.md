# 0006. Response bodies are checked against `contract/openapi.yaml` with a real JSON Schema validator

- Status: Accepted
- Date: 2026-10-07
- Phase: 10 (§10 — the three descriptions of the system must agree)
- Relates to: ADR-0001 (the API is tested against a fixed Postgres, handlers
  driven directly), ADR-017 (§1, §5.10 — the contract is the authoritative
  HTTP surface), ADR-0005 (`share_data_payload()` is the single builder of the
  card document)

## Context

Section 10 asks that the contract, the running API and the clients describe
the same system. `integration/` already compares **which** routes exist: the
paths `api/plumber.R` registers against `contract/openapi.yaml`, the three
routes of `share/` against `share.openapi.yaml`, and the paths
`app/R/api_client.R` and `share/R/api_client.R` actually call.

Nothing compared **what comes back**. The contract documents 107 responses
and every one of them names a schema (24 at the response itself, the rest via
the eight shared `#/components/responses/*` entries) across 29
`components.schemas` — a substantial promise, and an entirely unchecked one.
Rename a field, loosen a type, drop a key from `required` and every test in
the repository stays green.

The vocabulary is small and knowable: the contract uses exactly twelve JSON
Schema keywords — `type`, `properties`, `required`, `$ref`, `enum`, `format`,
`items`, `oneOf`, `maximum`, `minimum`, `maxLength` and `additionalProperties`
(the last only ever `false`). That is what made writing our own checker look
attractive, and what the decision below rejects.

## Decision

**A response is checked by ajv against the schema `contract/openapi.yaml`
names for that route and status — never by a validator we wrote.**

- `api/tests/testthat/helper-contract.R` reads the contract with `yaml`,
  rewrites `#/components/schemas/X` to `#/$defs/X` throughout, and compiles
  one validator per schema with `jsonvalidate` + `V8` (`engine = "ajv"`,
  `strict = FALSE`).
- `expect_contract_response(response, method, path)` resolves
  `(method, path, status)` → schema name and validates the body against it.
  An **undocumented status fails the test**; so does a documented response
  with no body. A bare `expect_contract(body, "Error")` covers the catch-all
  404, which has no route to look up.
- `yaml`, `jsonvalidate` and `V8` live in `api/default.dev.nix` and nowhere
  else — the same rule `testthat` follows: `nix/r-api.nix` is a layer of the
  production image and no deployment validates a response body.
- `api/tests/testthat/test-contract-conformance.R` drives the real handlers
  (the fixtures of `helper-experiments.R` and `helper-sim.R`) and asserts
  **104 expectations** over the contract's own schemas.

## Alternatives

- **A hand-rolled checker in R over the twelve keywords.** Rejected because it
  would be a second implementation of JSON Schema that can disagree with the
  first — precisely the drift this test exists to catch. Two concrete traps
  make "it's only twelve keywords" misleading: `toJSON(auto_unbox = TRUE)`
  collapses length-1 vectors, so `required: [experiment_id]` serialises as the
  scalar `"experiment_id"` and ajv refuses to compile the schema ("required
  value must be array") — the helper now has to restore the brackets; and
  JSON has no way to tell R's `2` from `2.0`, so `type: integer` against a
  value that came back as a whole double is a judgement call a checker has to
  make. Rejecting schemas containing keywords it does not implement would
  catch additions but not mis-implementations of the ones it does accept.
- **Spectral in CI.** Rejected: Spectral lints the *document*, not an
  *instance*. It cannot tell that `/share-data` answered `null` where the
  contract asked for an integer.
- **A validating proxy (Prism) in front of the API.** Rejected: it inserts a
  Node process between the tests and the handlers, and ADR-0001 already chose
  to drive handlers directly against a fixed Postgres rather than through an
  HTTP server. The proxy would also have to authenticate as an internal
  client and reproduce the middleware chain the unit tests deliberately skip.
- **Put the check in `integration/`.** Rejected: that package runs with **no
  services** by design and only reads files — it is the one place that proves
  the repo can be checked without Docker. Response bodies only exist while a
  handler is running, which is `api/`'s fixtures.
- **Do nothing** — keep relying on the route-level checks. Rejected because
  §10 asks for three descriptions of the same system, and "same routes,
  whatever bodies" is not a system described three ways.

## Consequences

- **`format` is not enforced.** ajv has no `int64` / `uuid` / `email`
  vocabulary without `ajv-formats`, and `strict = FALSE` means those keywords
  are ignored rather than fatal. That is what OpenAPI and JSON Schema say by
  default (`format` is an annotation), so nothing is being silently waived —
  but if we ever want `format` enforced, `ajv-formats` has to be added to the
  build and `strict` reconsidered.
- **The dev shell grows by three packages**, `V8` being the substantial one.
  It never reaches an image.
- **`POST /sensitivity` is only checked down its 503 branch.** A 200 needs the
  model files and `/data` mounted; the route's body schema is therefore not
  exercised in CI, which runs without models.
- **Three of the 29 schemas are unexercised**: `SensitivityResponse` (above),
  and `TripsSampleResponse` / `GeoJsonFeatureCollection`, whose routes are
  documented but not implemented — the known divergence already recorded in
  `CHANGELOG.md` and pinned by `integration/`.
- **The first run found four real defects**, which is the argument for the
  test rather than against it:
  1. `POST /experiments/{id}/feedback` **without** `comment` — optional in the
     contract — died in `db_lit()` ("expects a scalar") and answered 503
     "Database unavailable", a status the contract did not document for that
     path. Fixed by treating a missing comment as SQL `NULL`; `503` added to
     the contract, consistent with `/finish` and `/abandon`.
  2. `db_finish_experiment()` accepted `trips_accepted` and `trips_rejected`
     and **never wrote them** — and `001_init.sql` has no such columns. So
     `GET /share-data/{token}` returned `null` for two required integers: the
     public card could show no trip counts at all. Fixed by deriving them
     from the player's decisions, the same source `POST /finish` uses for
     `result$trips_accepted`.
  3. `Experiment.feedback.comment` is emitted as `null` when there is no
     comment, while the schema said `type: string`. Now
     `type: [string, "null"]`, the same spelling the contract already uses
     for `finished_at`.
  4. `integration/test-router-auth.R` still required the header catch-all to
     *be* `internal_auth_header`; section 11 moved it to `request_context`,
     which wraps auth. The test now asserts both the registration **and**
     that `request_context` performs the internal-key check, so narrowing the
     hook back out would still fail.
- **Divergences:** none with the master document. §10's requirement that the
  descriptions agree is met for bodies of the routes that exist; the two
  documented-but-unimplemented routes remain the annotated divergence.
- **Follow-ups:** enforce `format` if it ever matters; cover `/sensitivity`'s
  200 branch behind a "models are mounted" skip; drop the two unimplemented
  paths from the contract or implement them.
