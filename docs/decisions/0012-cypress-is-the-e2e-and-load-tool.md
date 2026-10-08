# 0012. Cypress is the UI's end-to-end and load tool; shinytest2 goes

- Status: Accepted
- Date: 2026-10-08
- Phase: 8 (§14 — load testing and hardening), §10 (shinytest2 flow),
  §12 (pa11y)
- Relates to: ADR-0011 (the development image this runs in), ADR-0007
  (which removed `shinytest2` from the runtime sets), master document §10,
  §12 and §8

## Context

Phase 8 says *"run `shinyloadtest` with 1, 10 and 20 users"*. Measuring the
tool first says that cannot be done as written:

- `shinyloadtest` 1.2.1 **does not generate load**. `load_runs()` translates
  directories produced by **`shinycannon`**; the R package only records
  sessions and analyses the result.
- `shinycannon` is **not in the pin** (`builtins.hasAttr` → false). It ships
  as a 9 MB jar behind `exec java -jar "$0"`, so it needs a JDK we do not
  carry.
- Its input is a **recording**, and `record_session()` produces one by
  blocking in `httpuv::service(Inf)` while a human drives a browser. There is
  no headless mode; automating it means driving a browser ourselves — which
  is the tool Cypress already is.

So the choice was never "shinyloadtest vs Cypress"; it was "build a
shinycannon harness we do not have, or adopt the tool that does both jobs".
Cypress also covers the rest of §10's browser-facing list and §12's `pa11y`,
which §10 keeps manual today.

Decisions taken alongside (all six were put to the question before anything
was written):

| Question | Decision |
|---|---|
| Where do "resources per user" come from | **the server**: CPU and RSS of the Shiny process while N sessions run, not Cypress's own timings (those measure the browser driving it) |
| How N concurrent users run | **N sessions against one app** — the unit ShinyProxy scales (`max-total-instances`) |
| What moves to Cypress | only `test-shinytest2.R`'s 14 scenarios, plus `pa11y` via Lighthouse; the ~1 500 R assertions that are not browser tests stay |
| The old strategy | **deleted, no traces**: `test-shinytest2.R`, `shinytest2`, `chromode`'s role and `chromium`. `app/dev/mock_api.R` **stays** — Cypress needs an API to talk to (**the second half superseded by [`0014`](0014-the-ui-tests-the-real-api.md)**: the suite talks to the real API, so the mock goes too) |
| Where Cypress lives | **baked into the development image** (layer 11), because it does not change often |
| Order | migrate **in parallel**, delete the old test only when the 14 scenarios are green in CI |

## Decision

**The Shiny app's end-to-end tests, its accessibility check and its load
measurements are written in Cypress. `shinytest2` is removed when the last of
the 14 scenarios has landed.**

- **`app/dev/e2e.sh`** owns the processes Cypress cannot start (the API,
  share/, the client-IP proxy and the app), waits for the app to answer
  *saying why it did not* if it never does, and runs `cypress run`.
- **`app/cypress.config.cjs`** is a plain object, not `defineConfig()`:
  Cypress is installed once in the image rather than in `node_modules`, so
  `require("cypress")` would fail with "Cannot find module".
- **Waiting is on selectors, not on idleness.** Shiny keeps a WebSocket open,
  so Cypress's network-idle detection never settles — the same reason the
  shinytest2 tests waited for `#setup-validate`.
- **`nix/node.nix` + Dockerfile layer 11**: node from Nix; Cypress from npm,
  because `pkgs.cypress` is marked insecure in this pin and granting
  `permittedInsecurePackages` means editing `nix/pkgs.nix`, which invalidates
  every layer above it (ADR-0011's lesson). The Electron libraries come from
  `apt`, the way Layer 1 already does — the list was installed in a running
  container and `cypress verify` answered **"Verified Cypress!"** before it
  was written down.

## Alternatives

- **Finish the `shinycannon` chain.** Rejected: a JDK derivation, a jar from
  a GitHub release, and an automated recording driven by chromote — several
  moving parts, none verifiable quickly, to reproduce a tool Cypress replaces.
- **`playwright` instead** (also in the pin). Rejected only because Cypress
  was chosen: it has the same Shiny-waiting problem, so nothing about the
  hard part changes.
- **Keep `shinytest2` for state assertions, Cypress for network/video/load.**
  Rejected by the "no traces of the old strategy" requirement, and because two
  frameworks answering the same question is exactly how a suite rots.
- **Install Cypress per project with npm** (`app/node_modules`). Rejected: it
  puts ~200 MB in the repository's working tree on every checkout and needs a
  network download per fresh environment, where the image already has it.
- **Measure with Cypress's own timings.** Rejected: they measure the browser
  driving the app, and `max-total-instances` has to be sized from the server.

## Consequences

- **The development image grew from 7.51 GB to 8.97 GB** — node, the Cypress
  package, its cached binary and the Electron libraries. It is a development
  image: no deployment one carries any of it (ADR-0007 already kept
  `shinytest2` out of them, and this does not change that).
- **The image and the tool now move together.** Cypress, its cache folder and
  the PATH live in layer 11 at the *end* of the Dockerfile, so an R or nix
  change does not invalidate them; a Cypress upgrade does.
- **`CYPRESS_CACHE_FOLDER` and the PATH must be set inside the script.**
  `nix-shell` keeps exported variables, but an SSH session does not inherit
  the container's environment at all, and the first run looked in
  `~/.cache/Cypress` and reported "No version of Cypress is installed".
- **§10's load testing moves to `app/dev/load_test.sh`** (N sessions, two
  decision strategies, server CPU/RSS) and **§8's "PNG cache hits" is
  unreachable**: Plan D (ADR-0010) removed the cache it counted. Divergences
  annotated in `CHANGELOG.md`.
- **The 14 scenarios are a migration, not a rewrite**: both suites ran until
  the last one landed. `test-shinytest2.R`, the mock it drove, `shinytest2`
  and the `chromium` it drove are all gone — the mock half of "the old
  strategy" superseded by [`0014`](0014-the-ui-tests-the-real-api.md), the
  rest as the deletion commit this ADR called for. It changed `nix/`, so the
  development image was rebuilt and pushed.
