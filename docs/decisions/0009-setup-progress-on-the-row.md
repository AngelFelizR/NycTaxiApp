# 0009. The setup percentage lives on the row, published by the child

- Status: Accepted
- Date: 2026-10-07
- Phase: 3 and 4 (§4.6 — the asynchronous create and `GET /state`)
- Relates to: ADR-0007 (the package the reader now lives in), master document
  §4.6 (which describes the `model_progress` field and nothing about where it
  is computed)

## Context

`POST /experiments` answers in ~0.2 s and forks the two trajectory
computations; while they run the row sits in `setup` and the client polls
`GET /state` for `model_progress`, a 0–99 number that only means something
until the status flips.

Where that number came from was the problem. It was **derived**: count the
rows already persisted for `policy`, and if the `baseline` batch had landed,
say 99. Three properties of that design are worth naming because they are what
this decision is about:

- **it needs both trajectory tables.** A reader that only wanted a percentage
  had to load two tables and evaluate a formula over them;
- **it is meaningful only to a process that can see both.** The number is
  computed, not stored, so it exists nowhere a *different* process could read
  it without redoing the same work;
- **`model_state$traj_jobs` is process memory.** It holds the forked children
  so `/state` can reap them. After a restart — or on another replica — it is
  empty, which is correct for reaping and useless for anything else.

Section 4.6 specifies the field and its 0–99 range; it does not say where it
is computed, and `contract/openapi.yaml` describes the response, not the
storage. So the shape could stay and the source could move.

## Decision

**The child publishes the percentage on the `experiments` row; `/state` reads
it from there.**

- **`api/migrations/002_setup_progress.sql`** adds
  `setup_progress SMALLINT CHECK (setup_progress IS NULL OR setup_progress
  BETWEEN 0 AND 99)`. `NULL` means nothing has been published yet, which the
  reader renders as 0.
- **The child publishes every five steps**, in the writer that already chunks
  the policy trajectory at `chunk_size = 5`, and once with `99` after the
  baseline batch — one extra `UPDATE` per chunk, twelve or so for a whole day.
  The statement is guarded: `... WHERE id = $1 AND status = 'setup'`. A child
  that outlives its parent, or that is simply slow, can no longer overwrite a
  day that has moved on; it gets `0 rows` back and that is not an error.
- **`GET /state` reads the row once, with `FOR SHARE`.** The body is built
  from that one snapshot.
- **`model_state$traj_jobs` stays exactly what it is: a fork table to reap
  from.** It is not read to build a response and never was.
- **The timeout does not move.** `SETUP_TIMEOUT_S` is still measured against
  `created_at`, so a child that dies leaves its last published number behind
  and the row is still retired on schedule. The column is a report, not a
  heartbeat.

`contract/openapi.yaml` is not touched: `DayState.model_progress` keeps its
type, range and condition, and `Experiment` never exposed it.

## Alternatives

- **A heartbeat column** (the child updates every N seconds so a dead one is
  detectable). Rejected: the child already has a natural cadence — the chunk
  write — so a timer would be a second mechanism for the same thing; and a
  heartbeat invites the mistake this decision avoids, of making liveness
  depend on it. §4.6's timeout must stay a function of `created_at`.
- **Keep deriving it from the trajectory tables.** Rejected because it makes
  every poll read two tables it otherwise has no reason to touch, and because
  "compute it here" and "publish it there" answer the same question with two
  implementations that can disagree. It also *happened* to work: the number
  was right because writes are chunked and the baseline is a single batch —
  a property of the writer, not a guarantee to the reader.
- **Keep it in `model_state` (process memory).** Rejected outright: that is
  the property being removed. A restarted parent would answer 0 for a day
  halfway through.
- **Use `traj_jobs` as the source of truth** (reading how many children are
  still running, or their pids). Rejected as the plan's option (b): a fork
  table is per-process by definition, so it cannot be a source of truth for
  anything a replica has to agree on. It stays for zombie reaping, which is
  precisely the use that does not need agreement.
- **`SELECT ... FOR UPDATE` instead of `FOR SHARE`.** Rejected: `/state` is a
  reader and would block every other reader for the duration of the statement.
  `FOR SHARE` still waits for an in-flight `UPDATE`, which is the transition
  that matters here (setup → in_progress).
- **Hold the lock across the whole handler** with an explicit transaction, so
  the row truly cannot change between read and response. Rejected: it would
  mean a pool checkout spanning `replay_user()` and the trajectory loads for
  no observable gain — the response is built from one snapshot either way, and
  MVCC already refuses to show a half-applied `UPDATE`. What `FOR SHARE` buys
  is stated in the code comment rather than oversold here.

## Consequences

- **Rows that exist before the migration read 0** until a child publishes over
  them; in-flight experiments are milliseconds old at deploy time, and the
  value only ever rises.
- **A publish that fails does not fail the trajectory.** `db_try` swallows it
  and the percentage stalls — the timeout still retires the row, so the worst
  case is a frozen spinner for `SETUP_TIMEOUT_S` rather than a stuck day.
- **Out-of-range values are clamped in R as well as rejected by the CHECK**,
  because the contract promises 0–99 and a database error in the middle of a
  trajectory would be a worse failure than a slightly wrong number.
- **A non-UUID id is a no-op**, so the writer tests (which pass a placeholder)
  do not make Postgres reject an update on every chunk.
- **Five tests** in `api/tests/testthat/test-setup-progress.R` pin the five
  properties: the migration and its bounds; the status guard; that `/state`
  answers a published 42 while the row counts would answer 99; that the answer
  is identical with and without the local job table; and that age, not
  progress, decides the timeout.
