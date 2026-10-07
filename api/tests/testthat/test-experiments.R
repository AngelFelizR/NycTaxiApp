# Phase 3 end-to-end: POST /experiments and everything under
# /experiments/{id}/..., plus /share-data, /waitlist and /metrics.
#
# Real Postgres and Redis (the root compose), planted trip week and the
# deterministic policy of helper-sim.R -- so no /data and no model file is
# needed, only the database and the cache.
#
# The plumbing (with_api_db, create_exp, status_of, ...) lives in
# helper-experiments.R so test-experiments-async.R can share it.

test_that("POST /experiments runs the three trajectories", {
  with_api_db({
    response <- create_exp()
    expect_identical(response$status, 201L)
    body <- response$body
    expect_true(is.character(body$experiment_id) && nchar(body$experiment_id) == 36)
    expect_true(is.character(body$resume_code) && nchar(body$resume_code) == 22)
    expect_true(is.character(body$share_token) && nchar(body$share_token) == 12)
    expect_identical(body$status, "in_progress")
    expect_identical(body$clock, "2024-05-12 08:00:00")
    expect_identical(body$current_location_id, 61L)
    expect_identical(body$current_zone, "Brooklyn - Crown Heights North")
    expect_identical(body$pct_following_policy, 100)
    expect_identical(body$pending_hours, 8)

    # Fresh day: the first offer and a history that is just the origin.
    expect_true(is.list(body$next_trip))
    expect_identical(body$next_trip$recommendation, "accept")
    expect_identical(body$history$step, 0L)
    expect_identical(body$result, NA)

    drop_experiment(body$experiment_id)
  })
})

test_that("custom seeds are marked and payload validation follows the contract", {
  with_api_db({
    custom <- create_exp(create_payload(seed = 7))
    expect_identical(custom$status, 201L)
    # seed_is_custom lives on the record (section 3.4), not on the creation
    # response, so it is read back through GET /experiments/{id}.
    custom_record <- fake_response()
    get_experiment_handler(
      fake_request(exp_headers(resume = custom$body$resume_code)),
      custom_record, custom$body$experiment_id
    )
    expect_null(custom_record$status)
    expect_true(custom_record$body$seed_is_custom)
    expect_identical(custom_record$body$seed, 7)
    drop_experiment(custom$body$experiment_id)

    bad <- list(
      list(payload = create_payload(company = NULL), status = 400L, msg = "company"),
      list(payload = create_payload(company = "Via"), status = 400L, msg = "company"),
      list(payload = create_payload(start_datetime = "noon"), status = 400L, msg = "ISO 8601"),
      list(payload = create_payload(start_location_id = 1.5), status = 400L, msg = "integer"),
      list(payload = create_payload(start_location_id = 999), status = 422L, msg = "between 1 and 265"),
      list(payload = create_payload(start_location_id = 264), status = 422L, msg = "TLC zone"),
      list(payload = create_payload(seed = "abc"), status = 400L, msg = "seed"),
      list(payload = create_payload(seed = -1), status = 422L, msg = "seed"),
      list(payload = create_payload(email = "nope"), status = 422L, msg = "email"),
      list(payload = create_payload(
        start_datetime = "2024-05-12T00:00:00Z"
      ), status = 422L, msg = "8h30")
    )
    for (case in bad) {
      response <- create_exp(case$payload)
      expect_identical(response$status, case$status)
      expect_match(response$body$message, case$msg, fixed = TRUE)
    }
  })
})

test_that("experiment endpoints require the resume code", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    on.exit(drop_experiment(id), add = TRUE)
    resume <- created$body$resume_code

    response <- fake_response()
    get_experiment_handler(fake_request(exp_headers()), response, id)
    expect_identical(response$status, 403L)

    response <- fake_response()
    get_state_handler(
      fake_request(exp_headers(resume = paste0(resume, "x"))), response, id
    )
    expect_identical(response$status, 403L)

    response <- fake_response()
    get_experiment_handler(
      fake_request(exp_headers(resume = resume)), response,
      "00000000-0000-4000-8000-000000000000"
    )
    expect_identical(response$status, 404L)

    response <- fake_response()
    get_experiment_handler(
      fake_request(exp_headers(resume = resume)), response, "not-a-uuid"
    )
    expect_identical(response$status, 404L)

    response <- fake_response()
    get_experiment_handler(fake_request(exp_headers(resume = resume)), response, id)
    expect_null(response$status)
    expect_identical(response$body$id, id)
    expect_identical(response$body$status, "in_progress")
    expect_identical(response$body$seed, 42)
    # The payload carries a seed, so the result is unofficial (section 3.4).
    expect_true(response$body$seed_is_custom)
    expect_identical(response$body$result, NA)
  })
})

test_that("decisions are replayed, idempotent and conflict-safe", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    on.exit(drop_experiment(id), add = TRUE)
    resume <- created$body$resume_code
    ip <- "10.0.0.9"
    first_trip <- created$body$next_trip$trip_id

    state <- fake_response()
    get_state_handler(fake_request(exp_headers(ip, resume)), state, id)
    expect_null(state$status)
    expect_identical(state$body$next_trip$trip_id, first_trip)

    decide <- function(payload) {
      response <- fake_response()
      create_decision_handler(
        fake_request(exp_headers(ip, resume)), response, id, json_raw(payload)
      )
      response
    }

    taken <- decide(list(trip_id = first_trip, accepted = TRUE))
    expect_null(taken$status)
    expect_identical(nrow(taken$body$history), 2L)
    expect_identical(taken$body$history$step, 0:1)
    expect_identical(taken$body$pct_following_policy, 100)
    second_trip <- taken$body$next_trip$trip_id
    expect_false(identical(second_trip, first_trip))

    # Same payload again: idempotent, no extra step.
    retry <- decide(list(trip_id = first_trip, accepted = TRUE))
    expect_null(retry$status)
    expect_identical(nrow(retry$body$history), 2L)

    # Same trip, opposite decision: 409.
    conflict <- decide(list(trip_id = first_trip, accepted = FALSE))
    expect_identical(conflict$status, 409L)
    expect_match(conflict$body$message, "different payload")

    # A trip that is not the one on offer: 409.
    foreign <- decide(list(trip_id = first_trip + 100000, accepted = TRUE))
    expect_identical(foreign$status, 409L)

    # Malformed payloads.
    expect_identical(decide(list(accepted = TRUE))$status, 400L)
    expect_identical(decide(list(trip_id = "x", accepted = TRUE))$status, 400L)
    expect_identical(decide(list(trip_id = 1, accepted = "yes"))$status, 400L)
    expect_identical(
      status_of(create_decision_handler, fake_request(exp_headers(ip, resume)),
                id, json_raw(list()))$status,
      400L
    )
  })
})

test_that("the day can be played, finished, shared and abandoned", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    on.exit(drop_experiment(id), add = TRUE)
    resume <- created$body$resume_code
    token <- created$body$share_token
    ip <- "10.0.0.10"

    ended <- play_day(id, resume, ip)
    expect_null(ended$status)
    expect_false(is.list(ended$body$next_trip))
    expect_identical(ended$body$history$step, 0:max(ended$body$history$step))

    finish <- fake_response()
    finish_experiment_handler(fake_request(exp_headers(ip, resume)), finish, id)
    expect_null(finish$status)
    result <- finish$body$result
    expect_identical(result$outcome, "tied_model")
    expect_identical(result$pct_following_policy, 100)
    expect_true(is.numeric(result$final_user_wage))
    expect_true(is.numeric(result$user_percentile))
    expect_gte(result$user_percentile, 0)
    expect_lte(result$user_percentile, 100)
    expect_gt(result$trips_accepted, 0)

    again <- fake_response()
    finish_experiment_handler(fake_request(exp_headers(ip, resume)), again, id)
    expect_identical(again$status, 409L)

    # A finished experiment keeps its record and the feedback.
    feedback <- fake_response()
    feedback_handler(
      fake_request(exp_headers(ip, resume)), feedback, id,
      json_raw(list(rating = 5, comment = "Great", public = TRUE))
    )
    expect_null(feedback$status)

    record <- fake_response()
    get_experiment_handler(fake_request(exp_headers(ip, resume)), record, id)
    expect_null(record$status)
    expect_identical(record$body$status, "finished")
    expect_identical(record$body$feedback$rating, 5L)
    expect_true(record$body$feedback$public)

    bad_feedback <- fake_response()
    feedback_handler(
      fake_request(exp_headers(ip, resume)), bad_feedback, id,
      json_raw(list(rating = 9))
    )
    expect_identical(bad_feedback$status, 422L)

    # Public share payload: aggregated, PII-free.
    share <- fake_response()
    share_data_handler(fake_request(list()), share, token)
    expect_null(share$status)
    expect_null(share$body$experiment_id)
    expect_null(share$body$resume_code)
    expect_identical(share$body$day_label, paste0("Day #", substr(token, 1, 6)))
    expect_identical(share$body$outcome, "tied_model")
    expect_true(is.numeric(share$body$final_user_wage))
    expect_gt(max(share$body$history$step), 0)

    expect_identical(status_of(share_data_handler, fake_request(list()), "a")$status,
                     404L)
    expect_identical(
      status_of(share_data_handler, fake_request(list()), "____________")$status,
      404L
    )

    # Abandoning a finished day is a conflict; a fresh one retires cleanly.
    expect_identical(
      status_of(abandon_experiment_handler, fake_request(exp_headers(ip, resume)),
                id)$status,
      409L
    )

    other <- create_exp()
    on.exit(drop_experiment(other$body$experiment_id), add = TRUE)
    abandoned <- fake_response()
    abandon_experiment_handler(
      fake_request(exp_headers(ip, other$body$resume_code)), abandoned,
      other$body$experiment_id
    )
    expect_null(abandoned$status)
    expect_identical(abandoned$body$status, "abandoned")
  })
})

test_that("share-email validates before touching SMTP", {
  with_api_db({
    created <- create_exp()
    id <- created$body$experiment_id
    on.exit(drop_experiment(id), add = TRUE)
    resume <- created$body$resume_code

    # Not finished yet and no SMTP configured: the contract's 422/503.
    early <- fake_response()
    share_email_handler(fake_request(exp_headers(resume = resume)), early, id,
                        json_raw(list(email = "driver@example.com")))
    expect_identical(early$status, 422L)
    expect_match(early$body$message, "not finished")

    no_email <- fake_response()
    share_email_handler(fake_request(exp_headers(resume = resume)), no_email,
                        id, json_raw(list()))
    expect_identical(no_email$status, 422L)

    malformed <- fake_response()
    share_email_handler(fake_request(exp_headers(resume = resume)), malformed,
                        id, json_raw(list(email = "nope")))
    expect_identical(malformed$status, 422L)
  })
})

test_that("POST /waitlist validates, limits and stores", {
  with_api_db({
    ip <- random_test_ip()
    email <- test_email("wait")
    on.exit(drop_waitlist(email), add = TRUE)

    sign_up <- function(address, headers) {
      response <- fake_response()
      waitlist_handler(fake_request(headers), response,
                       json_raw(list(email = address)))
      response
    }

    ok <- sign_up(email, exp_headers(ip))
    expect_null(ok$status)
    expect_match(ok$body$message, "waitlist")

    # Rejected payloads go through the limiter too (the limit runs before
    # validation), so they use their own address and leave the five signups
    # of `ip` intact.
    other <- random_test_ip()
    expect_identical(sign_up("nope", exp_headers(other))$status, 422L)
    expect_identical(
      status_of(waitlist_handler, fake_request(exp_headers(other)),
                json_raw(list()))$status,
      400L
    )

    for (i in 2:5) {
      addr <- test_email(paste0("wait", i, "_"))
      on.exit(drop_waitlist(addr), add = TRUE)
      expect_null(sign_up(addr, exp_headers(ip))$status)
    }
    limited <- sign_up(test_email("late"), exp_headers(ip))
    expect_identical(limited$status, 429L)
    expect_match(limited$body$message, "5 signups per day")
  })
})

test_that("GET /metrics reports every contract counter", {
  with_api_db({
    response <- fake_response()
    metrics_handler(fake_request(list()), response)
    expect_null(response$status)
    expect_named(response$body, c(
      "experiments_started", "experiments_finished", "experiments_abandoned",
      "shares_generated", "share_views_total", "sensitivity_cache_hits",
      "sensitivity_cache_misses", "png_cache_hits", "png_cache_misses",
      "waitlist_signups", "capacity_503_total"
    ))
    expect_true(all(vapply(response$body, is.numeric, logical(1))))
    # Creating an experiment moves the started counter.
    before <- response$body$experiments_started
    created <- create_exp()
    expect_identical(created$status, 201L)
    drop_experiment(created$body$experiment_id)
    after <- fake_response()
    metrics_handler(fake_request(list()), after)
    expect_gte(after$body$experiments_started, before + 1)
  })
})
