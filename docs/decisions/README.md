# Decision records

Where a decision lives, which file holds the reasoning, and the rule for
writing the next one.

## Where a decision goes

| Kind of decision | Where | Never here |
|---|---|---|
| Architectural tradeoff, with alternatives rejected | `docs/decisions/NNNN-slug.md` | AGENTS (it rots), CHANGELOG (too little room) |
| Which file answers a given topic/tool | `docs/TOPICS.md` (links only) | prose (a claim belongs in the file it describes) |
| Divergence from the master document | `CHANGELOG.md`, plus AGENTS if it changes the tree | never in the master document |
| Operational procedure | `docs/operations/runbook.md` (incident) · `first-deploy.md` (one-time) | ADRs |
| HTTP surface | `contract/*.yaml` — authoritative, linted in CI | prose |
| How to work in this repo | `AGENTS.md` | counts and totals, which go stale |
| History of what changed | `CHANGELOG.md` | ADRs |

## Rules

1. **An ADR is written in the same commit as the decision.** §18 of the master
   document planned 26 ADRs; 25 of them have no file precisely because this
   rule did not exist.
2. **Copy `_template.md`.** The `## Alternatives` section is mandatory: an ADR
   without it records a conclusion instead of a reasoning, and the next person
   re-litigates the same tradeoff.
3. **Never edit the master document** (`04 - Documento Maestro de Decisiones
   del Proyecto.md`). It has one commit — its creation. When code diverges,
   annotate in `CHANGELOG.md`.
4. Numbering is **sequential and local**: `0001`, `0002`, … It deliberately
   does not match §18's `ADR-0xx`, which is a *plan* inside an immutable
   document. The table below is the bridge between the two.
5. **A `Fixed` entry in `CHANGELOG.md` ends with a `**Lesson:**` line** —
   the portable lesson in one sentence, after the narrative of what broke
   and how it was fixed. A later reader (human or agent) extracts it with a
   `grep` instead of a close reading. Applies from this rule forward; past
   entries are not rewritten.

## Bridge: §18's planned ADRs and where their reasoning actually lives

§18 ("Índice de ADRs a Crear") asked for 26 ADR files. Only ADR-001 was ever
written, and it lives outside this directory. The other 25 decisions *are*
made — the master document states each with its justification — so they need
no duplicate file. This table exists so nobody writes one.

| §18 | Decision | Section | Reasoning lives in |
|---|---|---|---|
| ADR-001 | Monorepo vs. multi-repo | 1.2 | [`docs/REPO_DECISION.md`](../REPO_DECISION.md) |
| ADR-002 | PostgreSQL local vs. Supabase | 2.1 | master doc §2.1 |
| ADR-003 | 4 tables (incl. `waitlist`) | 2.2 | master doc §2.2 |
| ADR-004 | Write-through vs. batch on decisions | 2.5 | master doc §2.5 |
| ADR-005 | Models in an external release, verified at deploy | 4.5 | master doc §4.5 |
| ADR-006 | `mori` for shared memory | 4.1 | master doc §4.1 |
| ADR-007 | Zero `renderUI` for structure | 6.1 | master doc §6.1 |
| ADR-008 | Bidirectional Leaflet | 6.5 | master doc §6.5 |
| ADR-009 | PNG server-side with Redis/Cloudflare cache | 7.1 | master doc §7.1 — **partially superseded by [`0010`](0010-one-cache-layer-for-the-card.md)**: the Redis layer is gone, the edge header remains |
| ADR-010 | Single `share_token` with query params | 2.4 | master doc §2.4 |
| ADR-011 | No signature on `share_token` | 2.4 | master doc §2.4 |
| ADR-012 | Cloudflare in front | 8.4 | master doc §8.4 |
| ADR-013 | No Prometheus/Grafana, minimal alerts only | 11 | master doc §11 |
| ADR-014 | No visual-regression tests | 10 | master doc §10 |
| ADR-015 | Indefinite retention; PII erasable on request | 2.3, 9.1 | master doc §9.1 |
| ADR-016 | `X-Internal-Key` + `X-Resume-Code`, with an IP Plan B | 2.4, 5.4 | master doc §2.4, §5.4 |
| ADR-017 | API private, minimal public `share`, three Docker networks | 1, 5.10, 8.2 | master doc §1, §5.10 |
| ADR-018 | Custom seed = unofficial result; `outcome` server-side | 3 | master doc §3 |
| ADR-019 | Reference distribution and percentile | 4.6 | master doc §4.6 |
| ADR-020 | Privacy: `ip_hash`, separate consents, notice, manual erasure | 9.1 | master doc §9.1 |
| ADR-021 | English only, user-facing | 13 | master doc §13 |
| ADR-022 | Keyboard shortcuts: preselect + Enter | 6.5 | master doc §6.5 |
| ADR-023 | Resource budget: 10 instances (ceiling 12), swap, limits | 1.1 | master doc §1.1 |
| ADR-024 | No traffic lights in Trips; colour + icon in Results only | 3.11 | master doc §3.11 |
| ADR-025 | Definition of wage and tie-break rule | 3.9, 3.10 | master doc §3.9, §3.10 |
| ADR-026 | Mandatory demo and capacity page with waitlist | 8.2, 13 | master doc §8.2, §13 |

Revisit a row only when the decision is *changed*; the change then gets its own
sequential ADR here and the old row gets a note in its `Consequences`.

## ADRs written during implementation

Decisions the master document does not make, or makes differently.

| File | Relates to | Decision |
|---|---|---|
| [`0001-api-tests-use-fixed-postgres.md`](0001-api-tests-use-fixed-postgres.md) | §8 (differs from it) | Test suites use the root compose's Postgres, not testcontainers |
| [`0002-sensitivity-redis-cache.md`](0002-sensitivity-redis-cache.md) | — | Sensitivity endpoint cache semantics in Redis |
| [`0003-shared-visual-config.md`](0003-shared-visual-config.md) | §1.3, §6.4 (differs) | Visual configuration in `shared/*.yaml`, read by both frontends |
| [`0004-container-hardening.md`](0004-container-hardening.md) | §1.1, §5.10 (extends) | No capabilities, read-only roots, unprivileged user, CSP on the static pages -- and why ShinyProxy keeps `docker.sock` |
| [`0005-push-the-card-payload.md`](0005-push-the-card-payload.md) | §5.6, §5.10 (differs) | The API pushes the card payload to `share/` instead of `share` calling back into the request that is waiting for it |
| [`0006-response-schema-conformance.md`](0006-response-schema-conformance.md) | §10 | Response bodies are validated against `contract/openapi.yaml` with ajv, not with a checker we wrote |
| [`0007-both-services-are-packages.md`](0007-both-services-are-packages.md) | §10, §1.1, §6.2 (differs) | `api/` and `app/` are R packages: flat `R/`, installed in production, `load_all()` in development |
| [`0008-runtime-system-layer.md`](0008-runtime-system-layer.md) | §1.1, §8.6 | Images build a system layer without `nix` (~70 MB per image); the other 1.34 GB lives inside R and is left alone |
| [`0009-setup-progress-on-the-row.md`](0009-setup-progress-on-the-row.md) | §4.6 | The `setup` percentage is a column published by the child, not a count of trajectory rows; the timeout stays on `created_at` |
| [`0010-one-cache-layer-for-the-card.md`](0010-one-cache-layer-for-the-card.md) | §7.1, §11 (differs) | The card has one cache, the edge; `/metrics` reports renders instead of two counters nothing incremented |
| [`0011-runtime-r-without-the-toolchain.md`](0011-runtime-r-without-the-toolchain.md) | §1.1, §8.6 | R's output carries no JDK/compiler/Python; `glibc-locales` stays |
| [`0012-cypress-is-the-e2e-and-load-tool.md`](0012-cypress-is-the-e2e-and-load-tool.md) | §10, §12, §8 (differs) | Cypress does E2E, pa11y and load; `shinytest2` goes |
| [`0013-local-nix-binary-cache.md`](0013-local-nix-binary-cache.md) | §8.6 | A signed loopback Nix binary cache feeds the dev image: 54 min of layers → 5 |
| [`0014-the-ui-tests-the-real-api.md`](0014-the-ui-tests-the-real-api.md) | §10, §5.4, §5.6 (supersedes half of 0012) | The browser suite talks to the real stack; `dev/mock_api.R` and `test-shinytest2.R` are deleted |
| [`0015-mirror-third-party-images-into-ghcr.md`](0015-mirror-third-party-images-into-ghcr.md) | §8.6 | The images CI pulls are copied into `ghcr.io/angelfelizr/*`: a Docker Hub token runs too late to reach them |
| [`0016-one-r-per-pin-and-no-toolchain.md`](0016-one-r-per-pin-and-no-toolchain.md) | §1.1 | The pin slims its own R, so the compiled packages stop handing the toolchain back — ~1.4 GB per image |
## Execution still pending

Not decisions — work. Everything external to this repository is in
[`../operations/first-deploy.md`](../operations/first-deploy.md); the two
release gaps that abort the first deploy are in AGENTS, "Bloqueos del primer
despliegue".
