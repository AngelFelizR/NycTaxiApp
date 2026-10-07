# Plan C (docs/PLANS.md, ADR-0009): the "setup" percentage lives on the row.
#
# Four properties this is supposed to have, each one written down as a test
# because none of them is visible from the endpoint's shape -- the contract
# does not change, by design.

test_that("002 adds setup_progress and its CHECK bounds it", {
  with_api_db({
    created <- create_exp()
    expect_identical(created$status, 201L)
    id <- created$body$experiment_id
    on.exit(drop_experiment(id), add = TRUE)
    pool <- model_state$pool
    lit <- db_lit(pool, id)

    found <- DBI::dbGetQuery(pool, paste0(
      "SELECT column_name FROM information_schema.columns",
      " WHERE table_name = 'experiments' AND column_name = 'setup_progress'"
    ))
    expect_identical(nrow(found), 1L)

    # NULL is legal (nothing published yet) and 0/99 are the edges...
    DBI::dbExecute(pool, paste0("UPDATE experiments SET setup_progress = NULL WHERE id = ", lit))
    DBI::dbExecute(pool, paste0("UPDATE experiments SET setup_progress = 0 WHERE id = ", lit))
    DBI::dbExecute(pool, paste0("UPDATE experiments SET setup_progress = 99 WHERE id = ", lit))
    # ...and the next value is not.
    expect_error(
      DBI::dbExecute(pool, paste0("UPDATE experiments SET setup_progress = 100 WHERE id = ", lit)),
      regexp = "check|violat"
    )
    expect_error(
      DBI::dbExecute(pool, paste0("UPDATE experiments SET setup_progress = -1 WHERE id = ", lit)),
      regexp = "check|violat"
    )
  })
})

test_that("a stale child cannot overwrite a day that has moved on", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    on.exit(drop_experiment(id), add = TRUE)
    pool <- model_state$pool
    lit <- db_lit(pool, id)

    # POST /experiments runs inline here, so the day is already in_progress:
    # the guard makes this a no-op rather than a lie the client would read.
    expect_identical(db_publish_setup_progress(id, 7L), 0L)

    # Back in setup -- which is where a restarted replica would find a child
    # still writing -- the same call lands.
    DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET status = 'setup', setup_progress = NULL WHERE id = ", lit
    ))
    expect_identical(db_publish_setup_progress(id, 7L), 1L)
    got <- DBI::dbGetQuery(pool, paste0(
      "SELECT setup_progress FROM experiments WHERE id = ", lit
    ))[[1]]
    expect_identical(as.integer(got), 7L)

    # And a second publish overwrites, so progress really moves forward.
    expect_identical(db_publish_setup_progress(id, 42L), 1L)
    got <- DBI::dbGetQuery(pool, paste0(
      "SELECT setup_progress FROM experiments WHERE id = ", lit
    ))[[1]]
    expect_identical(as.integer(got), 42L)
  })
})

test_that("GET /state reports the published column, not a count of rows", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    resume <- created$body$resume_code
    on.exit(drop_experiment(id), add = TRUE)
    pool <- model_state$pool

    # Both trajectories are complete here, so the old derivation (rows in two
    # tables) would answer 99. Put the row back in setup with a value only the
    # child could have published, and the answer has to be that value.
    DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET status = 'setup', setup_progress = 42 WHERE id = ",
      db_lit(pool, id)
    ))
    state <- fake_response()
    get_state_handler(fake_request(exp_headers(resume = resume)), state, id)
    expect_null(state$status)
    expect_identical(state$body$status, "setup")
    expect_identical(state$body$model_progress, 42L)
  })
})

test_that("GET /state does not depend on the parent's in-memory job table", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    resume <- created$body$resume_code
    on.exit(drop_experiment(id), add = TRUE)
    pool <- model_state$pool
    DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET status = 'setup', setup_progress = 17 WHERE id = ",
      db_lit(pool, id)
    ))

    # With whatever the local process happens to be tracking...
    model_state$traj_jobs <- list(
      "99999" = list(job = NULL, started = Sys.time())
    )
    with_jobs <- fake_response()
    get_state_handler(fake_request(exp_headers(resume = resume)), with_jobs, id)
    expect_null(with_jobs$status)
    expect_identical(with_jobs$body$model_progress, 17L)

    # ...and with none, which is the state a different replica (or a parent
    # that has since restarted) starts from. Same answer either way.
    model_state$traj_jobs <- list()
    without <- fake_response()
    get_state_handler(fake_request(exp_headers(resume = resume)), without, id)
    expect_null(without$status)
    expect_identical(without$body$model_progress, 17L)
    expect_identical(without$body, with_jobs$body)
  })
})

test_that("the setup timeout is a function of created_at, never of progress", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    resume <- created$body$resume_code
    on.exit(drop_experiment(id), add = TRUE)
    pool <- model_state$pool
    lit <- db_lit(pool, id)

    # A row that has published every point it can, but is still too old: the
    # day is retired. Progress is not a heartbeat and never was.
    DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET status = 'setup', setup_progress = 99, ",
      "created_at = now() - interval '", SETUP_TIMEOUT_S + 10, " seconds' ",
      "WHERE id = ", lit
    ))
    expired <- fake_response()
    get_state_handler(fake_request(exp_headers(resume = resume)), expired, id)
    expect_identical(expired$status, 503L)
    expect_match(expired$body$message, "start again")

    # Conversely, no progress at all is not a timeout: age is what counts.
    fresh <- create_exp()
    fid <- fresh$body$experiment_id
    on.exit(drop_experiment(fid), add = TRUE)
    DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET status = 'setup', setup_progress = NULL WHERE id = ",
      db_lit(pool, fid)
    ))
    young <- fake_response()
    get_state_handler(
      fake_request(exp_headers(resume = fresh$body$resume_code)), young, fid
    )
    expect_null(young$status)
    expect_identical(young$body$model_progress, 0L)
  })
})
