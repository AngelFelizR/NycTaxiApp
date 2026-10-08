# 0014. The browser suite talks to the real API, and the mock is deleted

- Status: Accepted
- Date: 2026-10-08
- Phase: 8 (§14 load testing), §10 (UI tests), §5.4 (rate limit), §5.6 (share-email)
- Relates to: ADR-0012 (Cypress — it recorded that `app/dev/mock_api.R`
  **stays**; this supersedes that half of it), ADR-0001 (Postgres from the
  compose rather than testcontainers), ADR-0006 (response conformance)

## Context

ADR-0012 chose Cypress and left the mock in place with the note *"Cypress
needs an API to talk to"*. That is true and was never the question: the
question was whether the API it talks to should be a second implementation of
the product's rules. `app/dev/mock_api.R` was 507 lines of them — `mock_pending`,
`mock_state`, the precedence of §3.10, trip generation, the resume-code
guards — and **nothing** validated it against `contract/openapi.yaml`, so the
suite could pass while disagreeing with the service it stood in for.

Pointing it at the API it was imitating (2026-10-08) showed the drift was not
hypothetical:

| what | mock (canned) | API real |
|---|---|---|
| `better_datetime` for `2024-05-12T14:00:00Z` | `2024-05-12T20:00:00Z` | `2024-05-14T15:00:00Z` |
| the same field for the form's defaults | always answered, hint shown | echoed the input, so `validation_hints()` shows **no** datetime hint |
| rate limit | none | 3 per IP per UTC day, counted **before** validation — three attempts that failed with 400 still spent them, the fourth answered 429 |
| `/finish` percentile | a fixed `62nd` | `99th` of 1,000 simulated days, from `ReferenceDistribution.qs2` |

The scenario that asserted `has_text("#setup-datetime_hint", "2024-05-12T20:00:00Z")`
would have failed against the real API on both rows.

Section 10 asks the UI to surface 429, 403, 404, 409 and 503 and says, of the
Shiny test: *"simula un `httr2` que devuelve 429"*. So the document expects
one simulated status, not five live ones — and of the five, only 429 can be
produced by the network on demand. It is now produced for real.

## Decision

The UI suite runs against the API, share/, Redis, Postgres and SMTP — the
stack that runs in production — and `app/dev/mock_api.R`,
`app/dev/run_mock_api.R` and `app/tests/testthat/test-shinytest2.R` are
deleted.

- **`app/dev/e2e.sh` owns the stack.** It starts the API and `share/` when
  nothing answers on `TAXI_API_URL`, starts `app/dev/e2e-proxy.js`, starts the
  app, and tears down only what it started. The recipe is the same locally and
  in CI, which is the point: a second recipe is a second thing that can drift.
- **`app/dev/e2e-proxy.js` is where Nginx stands.** Shiny reads `X-Client-IP`
  off the WebSocket handshake and a page cannot set headers on a WebSocket, so
  against the app directly every session is `127.0.0.1` and the §5.4 test
  would compare the socket address with itself. The proxy injects
  `203.0.113.9` (TEST-NET-3) on both the HTTP requests and the upgrade;
  `client-ip.cy.js` asserts the API counted that address and not the socket.
- **The limiter is real, so the counter is reset per spec.** Each spec that
  creates days calls `cy.task("redis_flush_db")` in `before()` — Redis over
  raw RESP, no npm dependency — so the order of the run cannot decide the
  outcome; `rate-limit.cy.js` then spends its three attempts on purpose and
  asserts the API's own message.
- **§10's other four statuses stay where they are proven**: `test-api`,
  `api/dev/e2e_experiments.sh` and the contract-conformance tests. One real
  429 through the browser is what shows the notification path works — which is
  exactly what the shinytest2 test claimed when it injected one.

## Alternatives

- **Keep the mock and point Cypress at it** (ADR-0012's position) — rejected
  because it buys speed with a second implementation of §3.10 that nobody
  validates, and the first real comparison showed two of its answers wrong.
  The suite was measuring the mock.
- **Run both: mock by default, the real stack as a second job** — rejected on
  cost, not on principle: two suites means two environments to keep green, and
  the mock half is the one that can pass while the product is broken. The
  runtime difference is small anyway — the suite is ~3 minutes with the real
  API, because the create is asynchronous and returns in ~0.2 s.
- **A test-only header to inject 403/404/409/503 into the real API** —
  rejected: it is a status-injection backdoor in production code to save
  re-scoping one assertion, and §10 only asks for a simulated status anyway.
- **Provoke all five against the real API** — not possible: 403 needs a wrong
  `X-Internal-Key`, 404 an id the app will not send, 503 a missing model that
  would break everything else, 409 a decision the UI has no control over.
- **Let `cy.intercept` set the client IP**, as the plan in `docs/PLANS.md`
  assumed — rejected after measuring: intercept does not see WebSocket
  handshakes. The proxy replaced it, and the plan was corrected rather than
  left predicting something false.
- **Do nothing** — rejected: the mock was already wrong about the validation
  hint, and §5.6's share-email path (share/ + SMTP) was untested either way.

## Consequences

- **CI's `test-shiny` job is now an integration job.** It carries Postgres,
  Redis and mailpit as service containers, restores 562 MB of release assets
  from `actions/cache`, and verifies them with `infra/scripts/fetch-assets.sh`
  (§4.5). It runs the unit suite first, then `./dev/e2e.sh`. It also fires on
  `api/**` and `share/**` changes now, because the browser suite is one of the
  things that reads them.
- **The release stops CI until it is complete.** `fetch-assets.sh` aborts
  without `SHA256SUMS`, and `/finish` answers 503 without
  `ReferenceDistribution.qs2`. Both are the blockers already written down in
  `docs/operations/first-deploy.md` §1 — one upload fixes the deploy and this
  job.
- **The deletion commit ADR-0012 called for landed with this one**:
  `nix/test-tools.nix` is gone (chromium and `shinytest2` with it),
  `app/default.dev.nix` names a single library in `R_LIBS_SITE` again, and
  `NOT_CRAN` left both shells — nothing read it once AppDriver was gone. That
  changes `nix/`, so the image was rebuilt and pushed: **10.5 minutes, zero
  derivations compiled**, 978 paths served by the loopback cache of ADR-0013.
  It also saves the CI runner a download: chromium was fetched into the
  container's store on first use, ~1.3 GB that no spec used.
- **Local runs need Postgres, Redis and mailpit up** (`docker compose up -d`)
  and the release fetched; `./dev/e2e.sh` says which one is missing instead
  of timing out. That is the same contract the API suite already had.
- **No divergence with the master document.** §10's wording anticipated a
  simulated status and §5.4's limiter is enforced exactly as written; nothing
  in the document says the UI tests may use a stub.

- **Follow-ups:** `app/dev/load_test.sh` and pa11y (ADR-0012).
