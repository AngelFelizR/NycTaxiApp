# POST /experiments as it runs in production: the response comes back while
# the experiment is still in "setup" and the policy/baseline trajectories are
# computed in a forked child, which stores them in chunks of five. Everything
# else in test-experiments.R runs with API_EXPERIMENTS_SYNC=1 (inline).

# Writes a fresh snapshot of "decisions so far", the way simulate_day's
# on_step callback does, and records the size of every batch.
spy_writer <- function() {
  batches <- list()
  list(
    write = function(id, source, rows) {
      batches[[length(batches) + 1L]] <<- rows
      nrow(rows)
    },
    sizes = function() vapply(batches, nrow, integer(1))
  )
}

test_that("trajectory_writer stores the first 20 decisions in chunks of five", {
  spy <- spy_writer()
  w <- trajectory_writer("exp", "policy", write = spy$write)
  day <- data.frame(step = seq_len(21))
  for (i in seq_len(nrow(day))) w(day[seq_len(i), , drop = FALSE])

  # 5, 10, 15, 20 land as they are produced; 21 waits for the flush.
  expect_identical(spy$sizes(), c(5L, 5L, 5L, 5L))
  w(day, flush = TRUE)
  expect_identical(spy$sizes(), c(5L, 5L, 5L, 5L, 1L))
  expect_identical(sum(spy$sizes()), nrow(day))
})

test_that("trajectory_writer flushes a short day in one batch at the end", {
  spy <- spy_writer()
  w <- trajectory_writer("exp", "policy", write = spy$write)
  day <- data.frame(step = seq_len(12))
  for (i in seq_len(nrow(day))) w(day[seq_len(i), , drop = FALSE])
  # 5 and 10 are chunk boundaries, 11 and 12 are not: they wait.
  expect_identical(spy$sizes(), c(5L, 5L))
  w(day, flush = TRUE)
  expect_identical(spy$sizes(), c(5L, 5L, 2L))
  expect_identical(sum(spy$sizes()), nrow(day))
})

test_that("a lost write stops the simulation instead of promoting the day", {
  w <- trajectory_writer("exp", "policy", write = function(...) NULL)
  expect_error(w(data.frame(step = 1:5)), "failed to persist")
})

test_that("model_progress reports the background job without ever hitting 100", {
  none <- empty_decisions()
  expect_identical(model_progress(none, none), 0L)

  # model_progress only looks at row counts, so the rows themselves are stubs.
  policy <- data.frame(step = seq_len(30))
  expect_true(model_progress(policy, none) > 0L)
  expect_true(model_progress(policy, none) <= 94L)

  # Once the baseline batch is stored the experiment is one step from flipping.
  expect_identical(model_progress(policy, policy), 99L)

  big <- data.frame(step = seq_len(400))
  expect_identical(model_progress(big, none), 94L)
})

# A row in "setup" without a background job: the state a client sees while
# the model is still working, deterministic by construction.
setup_experiment <- function(resume) {
  # The resume code is deterministic, so a row a crashed run left behind would
  # break the unique hash and the insert would come back NULL. Any leftover is
  # removed first (decisions cascade).
  pool <- model_state$pool
  try(DBI::dbExecute(pool, paste0(
    "DELETE FROM experiments WHERE resume_code_hash = ",
    db_lit(pool, resume_hash(resume))
  )), silent = TRUE)

  created <- db_insert_experiment(
    participant_id = NULL,
    resume_code_hash = resume_hash(resume),
    # 12 characters and unique: the column carries a UNIQUE constraint.
    share_token = substr(sprintf("setuptoken%05d", test_seq()), 1, 12),
    seed = 42,
    seed_is_custom = FALSE,
    company = "Lyft",
    start_datetime = as.POSIXct("2024-05-12 08:00:00", tz = "UTC"),
    start_location_id = 61L,
    model_version = "test",
    app_version = "test",
    status = "setup"
  )
  if (is.null(created)) fail("could not insert the experiment in setup")
  created$id
}

test_that("GET /state serves a setup day and hides the offer", {
  with_api_db({
    resume <- sprintf("setup-code-%010d", test_seq())
    id <- setup_experiment(resume)

    response <- status_of(
      get_state_handler, fake_request(exp_headers(resume = resume)), id
    )
    expect_null(response$status)
    expect_identical(response$body$status, "setup")
    expect_identical(response$body$model_progress, 0L)
    expect_true(is.na(response$body$next_trip))
    expect_identical(response$body$history$step, 0L)
    expect_identical(response$body$result, NA)

    # Explicit, like the rest of the suite: an on.exit() registered here would
    # run after with_api_db has already restored model_state$pool.
    drop_experiment(id)
  })
})

test_that("decisions and finish wait for the model, abandon does not", {
  with_api_db({
    resume <- sprintf("setup-code-%010d", test_seq())
    id <- setup_experiment(resume)
    req <- fake_request(exp_headers(resume = resume))

    decision <- status_of(
      create_decision_handler, req, id,
      json_raw(list(trip_id = 1, accepted = TRUE))
    )
    expect_identical(decision$status, 409L)
    expect_identical(decision$body$message, "The day has not started yet.")

    finish <- status_of(finish_experiment_handler, req, id)
    expect_identical(finish$status, 409L)
    expect_identical(finish$body$message, "The day has not started yet.")

    abandon <- status_of(abandon_experiment_handler, req, id)
    expect_null(abandon$status)
    expect_identical(abandon$body$status, "abandoned")

    drop_experiment(id)
  })
})

# Runs `code` with API_EXPERIMENTS_SYNC set to `value` and restores the
# previous one on exit -- including when the code errors, which an on.exit()
# registered inside with_api_db() would not do reliably.
with_sync <- function(value, code) {
  old <- Sys.getenv("API_EXPERIMENTS_SYNC", "1")
  Sys.setenv(API_EXPERIMENTS_SYNC = value)
  on.exit(Sys.setenv(API_EXPERIMENTS_SYNC = old), add = TRUE)
  force(code)
}

test_that("the background job promotes the day and the player can then play", {
  # The fork deadlocks if libgomp did not see OMP_NUM_THREADS=1 when R
  # started (the nix shells export it), and a hang would be worse than a
  # skipped test.
  skip_if(!identical(.omp_at_start, "1"),
          "OMP_NUM_THREADS was not exported when R started")

  with_api_db({
    response <- with_sync("0", create_exp())
    expect_identical(response$status, 201L)
    body <- response$body
    expect_true(body$status %in% c("setup", "in_progress"))
    if (identical(body$status, "setup")) {
      # No offer yet: the day starts when the trajectories are stored.
      expect_true(is.na(body$next_trip))
      expect_true(is.integer(body$model_progress))
      expect_true(body$model_progress >= 0L && body$model_progress <= 99L)
    }

    resume <- body$resume_code
    id <- body$experiment_id

    # The forked child finishes the two trajectories and flips the row. The
    # poll is deliberately not an expect_* per iteration: the number of
    # iterations is timing, and that would make the suite's assertion count
    # drift.
    deadline <- Sys.time() + 60
    repeat {
      state <- status_of(
        get_state_handler, fake_request(exp_headers(resume = resume)), id
      )
      if (!is.null(state$status)) {
        fail("state poll answered ", state$status, ": ", state$body$message)
        break
      }
      if (identical(state$body$status, "in_progress")) break
      if (Sys.time() > deadline) fail("the background job never finished")
      Sys.sleep(0.25)
    }

    policy <- db_get_decisions(id, "policy")
    baseline <- db_get_decisions(id, "baseline")
    expect_true(nrow(policy) > 0L)
    expect_true(nrow(baseline) > 0L)
    # Chunked writes: every persisted step except the tail arrived in fives.
    expect_identical(head(policy$step, 20), 1:20)

    expect_true(is.list(state$body$next_trip))
    expect_identical(state$body$model_progress, NULL)

    decision <- status_of(
      create_decision_handler, fake_request(exp_headers(resume = resume)),
      id, json_raw(list(trip_id = state$body$next_trip$trip_id, accepted = TRUE))
    )
    expect_null(decision$status)
    expect_identical(decision$body$history$step, c(0L, 1L))

    drop_experiment(id)
  })
})
