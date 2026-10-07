# 0005. The API pushes the card payload to share/; share never calls back

- Status: Accepted
- Date: 2026-10-07
- Phase: 6 and 7 (`POST /experiments/{id}/share-email`, §5.6; `share/`, §5.10)
- Relates to: ADR-009 (§7.1, the PNG is rendered server-side by `share`),
  ADR-017 (§1, §5.10 — the API is private and `share/` is the public face)

## Context

Section 5.6 wants `POST /experiments/{id}/share-email` to be *synchronous*:
200 when the card was sent, 503 when it was not, so the visitor can retry.
Section 7.1 puts the rendering in `share/`, which gets its numbers from
`GET /share-data/{token}` (§5.10).

That makes the call graph a cycle:

```
API  ──GET /share/{token}.png──▶  share
API  ◀──GET /share-data/{token}──  share
```

plumber2 runs on httpuv and handles **one request at a time in the R process**,
so while the API is inside `share_email_handler` it cannot serve share's
callback. Measured on the running stack: a probe of `GET /health` recorded a
single response of **10 129 ms** during the E2E run — share's `req_timeout(10)`
— while every other sample was milliseconds. The sequence then plays out as:

1. the API blocks waiting for `share`;
2. share blocks for 10 s waiting for the API, and gives up with a transport
   error;
3. share answers 503 for the PNG;
4. the API turns that into the 503 the visitor sees.

`POST /share-email` therefore **can never succeed**, in development or in
production — the topology is the same in both. The E2E step that was written
to prove §5.6 works is what found it.

## Decision

**Break the cycle by removing the callback, not by relaxing the threading.**

- The API builds the `ShareDataResponse` itself through
  `share_data_payload()` — the same single builder `GET /share-data/{token}`
  uses, so the two paths cannot drift apart.
- `share/` gains an internal route **`POST /render-card`**: it takes that
  payload, renders the card and returns the bytes. It requires
  `X-Internal-Key`, which `share/` already receives.
- The public surface is untouched: `GET /share/{token}.png` still exists for
  crawlers and still pulls from the API — at a moment when nobody is blocked.

Data goes one way and comes back as bytes, so the cycle is gone.

## Alternatives

- **`async = TRUE` on the route** (plumber2's `@async`, backed by mirai).
  Rejected: the handler would run in a *different* R process without
  `model_state`'s database pool, and §5.6's synchronous answer depends on the
  handler actually running to completion here. It was not possible to confirm
  the engine's semantics cheaply, and a wrong guess breaks every database
  access in the endpoint.
- **Prime share's cache from `POST /finish` in a fire-and-forget mirai.**
  Rejected: it only moves the callback, and it is fragile — a visitor who
  emails their card without anyone having visited the share page would still
  deadlock.
- **Run the API as several processes** so one can block. Rejected: it changes
  the deployment model (connection handling, `mori` shared memory) to fix a
  call graph.
- **Render the card in the API.** Rejected: §5.10 and ADR-009 put rendering in
  `share/`, and the API image would grow by patchwork, ragg and a font stack
  to do work the public service already owns.

## Consequences

- **`share/` must be up for the card to be emailed.** That was already true
  (`fetch_share_png` existed and returned 503 when unreachable); only the
  direction of the call changed.
- **Section 5.6 is preserved unchanged**: 200 on success, 503 on failure, no
  queues, max 3 sends per experiment.
- **The share contract gains a path.** `contract/share.openapi.yaml` had
  `security: []` because everything in it was public; `POST /render-card`
  needs an `InternalKey` scheme declared for that path alone.
  **This diverges from §5.10**, which lists `share/`'s routes as
  `GET /share/{token}`, `GET /share/{token}.png`, `POST /waitlist`,
  `GET /health` (plus the Plan B `client-token`). Annotated in `CHANGELOG.md`;
  the master document is not edited.
- **The route is not reachable from the Internet.** Nginx proxies only
  `/share/` and `/waitlist`, and `share`'s port is `expose:`, never `ports:`.
  Anyone on `nyctaxi_api_net` could reach it, which is why it carries the key.
- **`shares_generated` counts one card per `GET /share-data/{token}`** and not
  the ones produced for an email. Left as-is rather than silently changing a
  metric; if the number should include emailed cards, that is a follow-up.
- The payload travels over the private network as JSON, the same document the
  public endpoint returns, so it inherits §5.7's guarantee: no
  `experiment_id`, no email, no IP.
