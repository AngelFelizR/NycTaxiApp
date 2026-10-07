# 0003. Visual configuration lives in shared/*.yaml

- Status: Accepted
- Date: 2026-10-06
- Phase: 6 (results & share)

## Context

The Results screen (`app/R/mod_results.R`) and the share card
(`share/R/render_png.R`) draw the *same* three cumulative curves. Section 7.1
of the master document only fixes their meaning and order ("3 curvas
acumuladas (user/policy/baseline)"), not their colour, so both implementations
had grown their own copy:

| | `app/` | `share/` |
|---|---|---|
| Legend labels `You` / `Model` / `Accept all` | `app/R/strings.R` | `share/R/render_png.R` |
| Colours `#6d5dfc` / `#0369a1` / `#94a3b8` | `mod_results.R` | `share/R/render_png.R` |

The brand token `#6d5dfc` was spelled out in six more places (`theme.R`,
three Leaflet accents, the sensitivity gradient, the share CTA). Nothing kept
the card and the page in agreement, and the whole point of the card is that a
visitor who clicks through from LinkedIn lands on a chart that looks the same.

Two constraints frame the choice:

- **The master document is never edited.** §1.3 lists the tree without
  `shared/`, and the §6.4 snippet still shows the palette literal inline in
  `theme.R`. Divergences are annotated (`CHANGELOG.md`, `AGENTS.md`), not
  corrected in the document.
- **`docs/REPO_DECISION.md` sets strict boundaries**: "La app nunca importa
  código de la API ni al revés; solo hablan por HTTP." Whatever is shared must
  not become a service dependency.

## Decision

The specification lives in **YAML under a new top-level `shared/`**:

- `shared/curves.yaml` — the three series: `name`, `label`, `colour`, in legend
  order.
- `shared/brand.yaml` — `primary` and `primary_dark` (§6.4).
- `shared/load.R` — the only code in the directory. It resolves the directory
  from a candidate list (`SHARED_DIR` → `./shared` → `../shared` →
  `../../shared` → `/srv/nyctaxi/shared`), reads both files **once** and caches
  the result, and exposes `curve_specs()`, `curve_labels()`, `curve_colours()`
  and `brand_colour()`.

Because YAML has no schema, `shared/load.R` also exports `validate_curves()` and
`validate_brand()` — exactly three series in the order `user, policy, baseline`,
non-empty unique labels, `^#[0-9a-fA-F]{6}$` unique colours, and
`primary != primary_dark` — each failing with a message a human can act on. They
are exported on purpose so both test suites can feed them malformed input.

Consumers:

- `app/R/strings.R` keeps `label_curve_*` as **aliases** of `curve_labels()`.
  §6.2 says that file holds the app's user-facing text, so deleting them would
  have traded one inconsistency for another.
- `app/R/shared_config.R` sources `shared/load.R` from inside `R/`. Shiny
  evaluates `R/*.R` **before** the body of `app.R` (verified with a probe), so
  the loader cannot live in `app.R`; it only works because `R/` is evaluated in
  alphabetical order (`constants` → `shared_config` → `state` → `strings`).
- `share/plumber.R` and both test helpers source it from their known root.

Dependency: `nix/r-shared.nix` holds `yaml`, imported by `nix/r-app.nix` and
`share/default.dev.nix`. The root shell picks it up automatically (`r-*.nix`).

## Alternatives considered

1. **A plain `.R` file instead of YAML.** Cheaper (no parser, no validators) and
   it was the first plan. Rejected because the user's intent was for the values
   to be *configuration* rather than code: YAML is editable by someone who does
   not read R, is obviously the thing to change when a colour changes, and keeps
   `shared/` free of logic. The cost is real and was accepted knowingly — `yaml`
   becomes a dependency of both frontends and the validators below have to exist.
2. **A small shared R package built by Nix.** Gives namespacing and removes the
   `source()` wiring entirely. Rejected: `app/` and `api/` are deliberately *not*
   packages (no `NAMESPACE`, no `man/`), `devtools`/`roxygen2` were removed from
   `r-dev.nix` to save ~75 MB of closure, and a derivation that must be rebuilt
   on every colour tweak is more machinery than three constants justify.
3. **Keep the duplication and add a cross-checking test.** Detects drift in CI
   instead of preventing it — and the canonical literal still has to live
   somewhere, so it only moves the problem.

## Consequences

- The card and the Results screen cannot drift: both call `curve_colours()`.
  A test asserts that the player's curve *is* the brand colour, so even that
  coincidence is now an explicit, conscious assertion.
- `grep -rn "6d5dfc" app/R share/R` returns nothing. A colour is never written
  inline again.
- Colours must be **quoted** in YAML. `colour: #6d5dfc` opens a comment and
  parses as `null`; `validate_curves()` reports exactly that, and a test feeds
  it the unquoted case.
- Startup cost: sourcing `shared/load.R` plus two `read_yaml()` calls is
  ~2 ms, inside a total `source()` of `app/R/` of 0.15–0.18 s. Measured warm
  startup stayed under the < 3 s criterion (2.52–2.71 s over five runs).
- **Phase 7 has two obligations**: the `Dockerfile` needs its `COPY
  nix/r-shared.nix` layer **before** layer 10 (otherwise `readDir ./nix` in
  `default.nix` silently builds a shell without `yaml`), and each deployment
  image must `COPY shared/`. `SHARED_DIR` is the override if a layout ever puts
  it elsewhere.
- Two divergences with the master document are annotated in `CHANGELOG.md`
  rather than resolved: §1.3's tree does not mention `shared/`, and the §6.4
  snippet still shows the literal inside `theme.R` (the values themselves are
  unchanged and the §6.4 palette table remains accurate).
