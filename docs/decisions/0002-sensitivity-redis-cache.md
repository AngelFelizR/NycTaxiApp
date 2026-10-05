# 0002. Sensitivity endpoint and Redis cache semantics

- Status: Accepted
- Date: 2026-10-05
- Phase: 2 (`04 - Documento Maestro de Decisiones del Proyecto.md` §5.5, §8, §14)

## Context

Phase 2 ports the Shiny decision-boundary exploration to the API: `POST
/sensitivity` must run `select_zone_with_high_change()` + `compute_decision_grid()`
(50x50 grid, 30x30 on mobile), return three grids (original, pickup-variant,
drop-off-variant) plus the suggestion metadata, and meet these criteria:

- cache key `sens:{experiment_id}:{trip_id}:{pu}:{do}` with TTL 1h,
- hit < 500 ms, cold < 2.5 s,
- timing always logged (§8 observability).

## Decisions

1. **Cache value is a wrapper `{"grid_size": N, "body": {...}}`.** The contract
   cache key has no slot for the grid size, but `X-Device: mobile` (30x30) and
   the default (50x50) share the same key. The wrapper keeps the contract key
   format untouched while preventing a mobile client from being served the
   50x50 payload (and vice versa).
2. **The cached value is the serialised JSON response.** On a hit it is parsed
   with `simplifyVector = TRUE` so grids come back as data frames and serialise
   quickly (~300 ms end to end). Serialising the value as nested lists cost
   ~2 s on the wire and was rejected.
3. **Nulls in JSON are `NA_integer_`, not `NULL`.** With `format_unboxed()`, a
   `NULL` element inside a list serialises as `{}`; `NA_integer_` becomes
   `null`. Cached hits fix `NULL` fields back to `NA` after parsing.
4. **Omitted `pickup_id`/`dropoff_id` means auto-select** the hardest zone
   within the prototype subset (boroughs Manhattan, Brooklyn, Queens), ported
   from the Shiny investigation. Explicit zones skip the suggestion (it is
   `null`).
5. **Headers:** `X-Client-IP` is required (400 without it) and `X-Device` must
   be `mobile` or `desktop` (400 otherwise). `grid_size` must be an integer in
   10..100 (422 outside the range); `X-Device: mobile` wins over `grid_size`.
6. **Redis is fail-open.** If Redis is unreachable the endpoint recomputes
   every time; the cache is an optimisation, never a source of truth. (The
   phase-3 rate limit will fail closed instead.)
7. **Trip identity is the `trip_id` column** of the parquet (not a row
   number), resolved with `findInterval()`; unknown trips return 404. Zone
   labels come from `ZonesShapes.qs2`; ids 264/265 have no geometry and fall
   back to `"(id)"`.
8. **Timing is always logged** as
   `sensitivity: hit=TRUE|FALSE ms=... grid=... trip=... compute=...ms`.

## Consequences

- `nix/r-api.nix` gains `nanoparquet` (data) and `redux` (Redis client); the
  dataset is mounted read-only at `/data` (`DATA_DIR`).
- Loading the parquet adds ~297 MB resident (RSS ~974 MB, budget 1.2 GB) and
  ~0.7 s startup.
- Measured: cold ~0.9 s (< 2.5 s), hit ~0.34 s (< 500 ms), byte-identical
  bodies on a hit; Redis holds one key per experiment/trip/zones combo.
- The contract key stays exactly as specified in `contract/openapi.yaml`; the
  wrapper is an internal detail of the value, not of the key.
