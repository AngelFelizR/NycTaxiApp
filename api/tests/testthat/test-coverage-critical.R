# The four files section 10 requires at 100% that were short of it.
#
# Every case here is a branch the report named: migrations that cannot be
# applied, a header that is whitespace, a day with no data, a replay that
# disagrees with what was stored, and the reference distribution that may or
# may not be on disk. The three files that were already at 100%
# (sensitivity, rate_limit, internal_auth) need nothing.

# --------------------------------------------------------------------------
# db_migrations.R -- every way ensure_schema() is allowed to give up
# --------------------------------------------------------------------------
test_that("ensure_schema fails soft, never throws", {
  # No pool at all: the API still starts, handlers answer 503.
  expect_false(ensure_schema(NULL))

  with_api_db({
    pool <- model_state$pool
    old_root <- model_state$repo_root
    old_ready <- model_state$schema_ready
    on.exit({
      model_state$repo_root <- old_root
      model_state$schema_ready <- old_ready
      ensure_schema(pool)
    }, add = TRUE)

    # repo_root unset: it says so and gives up rather than guessing a path.
    model_state$repo_root <- NULL
    expect_message(expect_false(ensure_schema(pool)), "repo_root")

    # A directory with no migrations in it is not a schema.
    empty <- tempfile("migrations-empty")
    dir.create(file.path(empty, "api", "migrations"), recursive = TRUE)
    model_state$repo_root <- empty
    expect_message(expect_false(ensure_schema(pool)), "no \\.sql files")

    # A migration that does not parse stops the run, and the message names
    # the file -- otherwise a broken deploy is indistinguishable from an
    # empty database.
    broken <- tempfile("migrations-broken")
    dir.create(file.path(broken, "api", "migrations"), recursive = TRUE)
    writeLines("this is not sql;", file.path(broken, "api", "migrations", "99_bad.sql"))
    model_state$repo_root <- broken
    expect_message(expect_false(ensure_schema(pool)), "99_bad\\.sql")
    expect_false(schema_ready())
  })
})

# --------------------------------------------------------------------------
# middleware_client_ip.R -- the edges of the two headers
# --------------------------------------------------------------------------
test_that("a whitespace-only client IP is unknown, not an empty counter", {
  expect_identical(client_ip_value(fake_request(list())), "unknown")
  expect_identical(
    client_ip_value(fake_request(list("x-client-ip" = "   "))), "unknown"
  )
  expect_identical(
    client_ip_value(fake_request(list("x-client-ip" = " 10.0.0.1 "))), "10.0.0.1"
  )
  # Hashed whatever it is: the clear address never reaches a caller.
  expect_match(
    client_ip_hash(fake_request(list("x-client-ip" = "10.0.0.1"))),
    "^[0-9a-f]{64}$"
  )
})

test_that("client_country takes a two-letter code and nothing else", {
  expect_identical(client_country(fake_request(list("cf-ipcountry" = "es"))), "ES")
  expect_null(client_country(fake_request(list())))            # absent
  expect_null(client_country(fake_request(list("cf-ipcountry" = ""))))   # empty
  expect_null(client_country(fake_request(list("cf-ipcountry" = "ESP")))) # not 2
  expect_null(client_country(fake_request(list("cf-ipcountry" = "E1"))))  # not a code
})

# --------------------------------------------------------------------------
# ml_simulate.R -- the branches a normal happy-path day never reaches
# --------------------------------------------------------------------------
test_that("normalize_seed folds anything into the legal range", {
  expect_identical(normalize_seed("42"), 42L)
  expect_identical(normalize_seed(-7), 7L)
  # Not a number at all: 0, so the day is still reproducible.
  expect_identical(normalize_seed("not-a-number"), 0L)
  expect_identical(normalize_seed(NA), 0L)
  # Beyond the 31-bit range the RNG accepts.
  expect_identical(normalize_seed(2147483648), 1L)
})

test_that("a day with no trip data ends instead of spinning", {
  # candidate_trips() returns NULL when the dataset is not ready, which is the
  # branch a fresh process without /data sits in. It has to break, not error.
  unplant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  sim <- simulate_day(42, "HV0005", sim_start_datetime(), 61L, "policy")
  expect_true(sim$ended)
  expect_identical(nrow(sim$decisions), 0L)
})

test_that("the step cap ends the day rather than looping forever", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  # 5000 is what production uses; three is enough to prove the guard, and the
  # constant is a binding, so it can be mocked like any other.
  local_mocked_bindings(SIM_MAX_STEPS = 3L, .package = "taxiapi")
  local_mocked_bindings(
    policy_probability = function(frame) rep(0.99, nrow(frame)),
    .package = "taxiapi"
  )
  sim <- simulate_day(42, "HV0005", sim_start_datetime(), 61L, "policy")
  expect_true(sim$ended)
  expect_lte(nrow(sim$decisions), 3L)
})

test_that("a policy that cannot answer stops the day as model_unavailable", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  local_mocked_bindings(
    policy_probability = function(frame) NA_real_,
    .package = "taxiapi"
  )
  sim <- simulate_day(42, "HV0005", sim_start_datetime(), 61L, "policy")
  expect_identical(sim$error, "model_unavailable")

  # The baseline asks the same function once, in bulk: a length that does not
  # match the day is as unusable as a missing answer.
  local_mocked_bindings(
    policy_probability = function(frame) rep(0.5, nrow(frame) - 1L),
    .package = "taxiapi"
  )
  base <- simulate_day(42, "HV0005", sim_start_datetime(), 61L, "baseline")
  expect_identical(base$error, "model_unavailable")
})

test_that("a replay that disagrees with what was stored says so and stops", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    start <- sim_start_datetime()
    first <- simulate_day(9, "HV0005", start, 61L, "user")$pending
    stored <- decision_row(1, first, TRUE, TRUE)
    # The stored trip is not the one the simulator offers next: the replay
    # has to stop and say why rather than quietly play a different day.
    stored$trip_id <- as.integer(stored$trip_id) + 1000L

    msgs <- capture.output(
      sim <- simulate_day(9, "HV0005", start, 61L, "user", recorded = stored),
      type = "message"
    )
    expect_match(paste(msgs, collapse = " "), "replay divergence")
    expect_identical(nrow(sim$decisions), 0L)
  })
})

test_that("the RNG state of the caller comes back the way it went in", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)

  # No .Random.seed at all: the day creates one, and on the way out the
  # on.exit has to remove it rather than restore something that never was.
  if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
    rm(".Random.seed", envir = globalenv())
  }
  simulate_day(42, "HV0005", sim_start_datetime(), 61L, "policy")
  # The day created one, and the on.exit removed it again: the caller's RNG
  # is left exactly as it found it, which is the branch that needs line 123.
  expect_false(exists(".Random.seed", envir = globalenv(), inherits = FALSE))

  # One that does exist: restored bit for bit, or the caller's next draw
  # would silently change.
  set.seed(1234)
  before <- .Random.seed
  simulate_day(42, "HV0005", sim_start_datetime(), 61L, "policy")
  expect_identical(.Random.seed, before)
})

# --------------------------------------------------------------------------
# ml_outcome.R -- the reference distribution and the share copy
# --------------------------------------------------------------------------
test_that("the reference distribution is read once, or honestly absent", {
  old_ref <- model_state$reference
  old_dir <- Sys.getenv("TAXI_MODELS_DIR", unset = NA_character_)
  on.exit({
    model_state$reference <- old_ref
    if (is.na(old_dir)) Sys.unsetenv("TAXI_MODELS_DIR")
    else Sys.setenv(TAXI_MODELS_DIR = old_dir)
  }, add = TRUE)

  # Nothing on disk: NULL, and the percentile follows -- finish answers 503
  # rather than storing a made-up number.
  model_state$reference <- NULL
  empty <- tempfile("models-empty")
  dir.create(empty)
  Sys.setenv(TAXI_MODELS_DIR = empty)
  expect_null(reference_distribution())
  expect_null(reference_percentile("Lyft", 30))

  # A file that is not a qs2 file. qs2 does not raise here -- it hands back
  # the message text -- so the reader has to recognise that and refuse it,
  # rather than caching a character vector as a reference distribution.
  bad <- tempfile("models-bad")
  dir.create(bad)
  writeLines("not a quasar", file.path(bad, "ReferenceDistribution.qs2"))
  Sys.setenv(TAXI_MODELS_DIR = bad)
  expect_null(reference_distribution())
  expect_null(reference_percentile("Lyft", 30))

  # A real one: read, cached, and consulted.
  good <- tempfile("models-good")
  dir.create(good)
  qs2::qs_save(list(by_company = list(Lyft = c(10, 20, 30, 40))), 
               file.path(good, "ReferenceDistribution.qs2"))
  Sys.setenv(TAXI_MODELS_DIR = good)
  ref <- reference_distribution()
  expect_true(is.list(ref))
  # Cached: pointing the models directory somewhere else must not change the
  # answer, which is what model_state$reference is for.
  Sys.setenv(TAXI_MODELS_DIR = empty)
  expect_identical(reference_distribution(), ref)
  # And once the cache is cleared with nothing to re-read: NULL again.
  model_state$reference <- NULL
  expect_null(reference_distribution())
  # A company nobody simulated: NULL, not zero.
  expect_null(reference_percentile("Via", 30))
})

test_that("every branch of the Results and share copy exists", {
  outcomes <- c("beat_model", "tied_model", "beat_baseline",
                "lost_to_baseline", "no_rides")

  # Section 6.6: one label per verdict, plus the unofficial wording.
  for (o in outcomes) {
    expect_true(nzchar(outcome_label(o)), label = paste("label for", o))
    expect_true(nzchar(outcome_share_text(o)), label = paste("share for", o))
    expect_true(nzchar(outcome_context_line(o)), label = paste("context for", o))
  }
  # The custom-seed wording overrides the verdict, and the contract allows an
  # unknown outcome to fall through to a neutral string rather than NA.
  expect_identical(outcome_label("beat_model", TRUE), "I simulated my own day")
  expect_identical(outcome_context_line("beat_model", TRUE),
                   "This day used a custom seed and is marked unofficial.")
  expect_identical(outcome_label("no-such-outcome"), "I simulated my own day")
  expect_identical(outcome_share_text("no-such-outcome"), "")
  expect_identical(outcome_context_line("no-such-outcome"), "")

  # Each verdict has its own sentence: they are what a stranger reads.
  expect_match(outcome_context_line("beat_model"),
               "more per hour than the XGBoost policy")
  expect_match(outcome_context_line("tied_model"), "You matched the XGBoost")
  expect_match(outcome_context_line("beat_baseline"), "beat accepting every ride")
  expect_match(outcome_context_line("lost_to_baseline"), "would have paid more")
  expect_match(outcome_context_line("no_rides"), "rejected every ride")
})
