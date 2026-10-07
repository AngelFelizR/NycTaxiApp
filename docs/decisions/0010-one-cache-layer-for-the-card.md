# 0010. One cache layer for the card: the edge, not Redis

- Status: Accepted
- Date: 2026-10-07
- Phase: 7 (§7.1 — the PNG is rendered server-side; §11 — `/metrics`)
- Relates to: **supersedes part of ADR-009** (§7.1, "PNG server-side with
  Redis/Cloudflare cache"), ADR-0005 (which made the payload of that card a
  single builder), master document §11 (which lists `png_cache_hits` and
  `png_cache_misses`)

## Context

Section 7.1 puts the card behind **two** caches: one in Redis (24 h TTL, so a
spike of crawlers never re-renders) and one at the edge (the `Cache-Control`
Cloudflare honours). The design was reasonable and the evidence against it
came from `/metrics`:

- **Nothing ever incremented `png:cache:hits` or `png:cache:misses`.** The API
  read both keys; the share service never wrote them. They have reported `0`
  since the day they were added, and the contract's example
  (`png_cache_hits: 3120`) described a number that could not exist.
- **The layer therefore hid the thing the metric was for.** With a 24 h Redis
  TTL in front, a busy card renders at most 24 times a day while `hits` says
  zero — the counter that would have said "we are being hammered" was the one
  being bypassed.
- **Redis being down already fails open.** `png_cache_get` returns `NULL`,
  the card is rendered fresh. So the cache was never load-bearing: removing it
  changes no failure mode, only the number of renders the edge has to absorb.

The edge does the job the Redis layer was doing. `Cache-Control: public,
max-age=86400, s-maxage=604800` on the PNG is unchanged, which is what
actually keeps crawlers and LinkedIn's crawler from reaching us twice.

## Decision

**The card is rendered on every request that reaches `share/`. The edge is the
cache. `/metrics` reports the work done, not a cache that is not there.**

- `share/R/cache.R` loses `png_cache_get` / `png_cache_put` / `png_cache_del`
  and `as_raw`. It keeps `share:views:{token}` (section 7.4) and gains one
  global counter, `png:renders`, incremented once per card actually painted —
  including the card pushed for an email (ADR-0005).
- `share/R/routes.R`'s `png_handler` fetches, renders and responds, with the
  same `Cache-Control` as before.
- **`Cache-Control` and the Cloudflare rule are untouched.** They are the
  cache now; nothing replaces them.
- **`contract/openapi.yaml`'s `MetricsResponse` loses `png_cache_hits` and
  `png_cache_misses`, gains `png_renders_total`.** Spectral passes.

`share:views`, the bot filter, `/health` and the sensitivity cache are not
part of this and did not move.

## Alternatives

- **Keep the Redis cache and fix the counters** (increment on hit and miss).
  Rejected: the measurement would then describe a layer that only exists
  between two edge expiries, and it would still be the only cache the metrics
  can see. The bug was not the missing increments; it was that a second cache
  makes the first one's hit rate unknowable from inside the app.
- **Keep the cache, drop the metrics.** Rejected for the same reason in
  reverse: an operator needs to know how often a card is painted, and "not at
  all, because Redis said no" and "not at all, because Cloudflare said no" are
  different facts.
- **Move the cache to be the only one by dropping the `Cache-Control`.**
  Rejected: §7.1 wants the card cacheable at the edge and the header is what
  buys that; removing it would re-render on every crawler hit — the exact
  problem, minus the metric.
- **Do nothing** — leave two counters that read zero forever. Rejected: a
  metric that can never move is worse than no metric, because someone will
  eventually read it as "we are not being crawled".

## Consequences

- **§7.1 of the master document describes three layers** (server-side PNG
  with Redis, plus the edge) and there are now two. **Annotated in
  `CHANGELOG.md`**; the document is not edited. The `Cache-Control` promise
  and the render location are unchanged, which is the part §7.1 cares about.
- **ADR-009 is partially superseded.** The bridge table in
  `docs/decisions/README.md` points its row here, per that file's own rule for
  a revisited decision.
- **§11's `/metrics` list changes**: `png_cache_hits` and
  `png_cache_misses` out, `png_renders_total` in. Anyone reading the old field
  will get a 422-free but `expect_named()`-breaking response — the contract
  and the one test that pins the names moved together.
- **Every public card request now costs a render.** That is `share_png()`
  per request, which is tens of milliseconds; behind the edge it only happens
  after an expiry. If that ever becomes a problem, the fix is a longer
  `s-maxage`, not a second cache inside the service.
- **The tally is best-effort** like the view counter: Redis down means the
  render is not counted and the card still arrives.
