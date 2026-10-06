# Session state (state.R): the IP forwarding the phase-4 deliverable checks,
# and the helpers that turn API answers into what the modules read.
# reactiveValues can only be read inside a reactive consumer, so every read
# here goes through isolate().

fake_session <- function(headers = list()) {
  structure(list(request = headers), class = "MockShinySession2")
}

test_that("client_ip prefers X-Client-IP, then CF-Connecting-IP, then peer", {
  expect_equal(client_ip(fake_session(list(HTTP_X_CLIENT_IP = " 203.0.113.9 "))),
               "203.0.113.9")
  expect_equal(client_ip(fake_session(list(HTTP_CF_CONNECTING_IP = "198.51.100.2"))),
               "198.51.100.2")
  expect_equal(client_ip(fake_session(list(REMOTE_ADDR = "127.0.0.1"))),
               "127.0.0.1")
  expect_equal(client_ip(fake_session()), "")
  expect_equal(client_ip(fake_session(list(HTTP_X_CLIENT_IP = "   "))), "")
})

test_that("estado_ctx forwards the IP and the resume code", {
  e <- fake_session(list(HTTP_X_CLIENT_IP = "203.0.113.9"))
  estado <- init_estado(e)
  estado$resume_code <- "Gh7Kq2mZx9LpW4vRt8Yb1c"
  ctx <- estado_ctx(estado)
  expect_equal(ctx$ip, "203.0.113.9")
  expect_equal(ctx$resume_code, "Gh7Kq2mZx9LpW4vRt8Yb1c")
  expect_equal(ctx$url, api_base_url())
})

test_that("estado_set_created stores the credentials and the state", {
  estado <- init_estado(fake_session())
  estado_set_created(estado, list(
    experiment_id = "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
    resume_code = "r0nescripts", share_token = "aZ3kQ9mLp1Rt",
    status = "setup", model_progress = 0L
  ))
  isolate({
    expect_equal(estado$experiment_id, "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    expect_equal(estado$resume_code, "r0nescripts")
    expect_equal(estado$share_token, "aZ3kQ9mLp1Rt")
    expect_equal(estado$status, "setup")
    expect_equal(estado$progress, 0L)
  })
})

test_that("model_progress only reports while the day is in setup", {
  estado <- init_estado(fake_session())
  estado_set_state(estado, list(status = "setup", model_progress = 42L))
  isolate(expect_equal(estado$progress, 42L))

  # The field disappears once the day starts: progress implies 100.
  estado_set_state(estado, list(status = "in_progress"))
  isolate({
    expect_equal(estado$progress, 100L)
    expect_true(estado_ready(estado))
  })
})

test_that("the result is kept only when the API actually returns one", {
  estado <- init_estado(fake_session())
  estado_set_state(estado, list(status = "in_progress", result = NULL))
  isolate(expect_null(estado$result))

  res <- list(final_user_wage = 27.4, outcome = "beat_model",
              pct_following_policy = 88, trips_accepted = 7, trips_rejected = 3)
  estado_set_state(estado, list(status = "finished", result = res))
  isolate({
    expect_equal(estado$result$final_user_wage, 27.4)
    expect_equal(estado$status, "finished")
    expect_true(estado_ready(estado))   # no longer waiting on the model
  })
})

test_that("estado_set_state ignores a NULL payload", {
  estado <- init_estado(fake_session())
  expect_null(estado_set_state(estado, NULL))
  isolate(expect_null(estado$state))
})

test_that("shift_over only fires when the clock has actually run out", {
  expect_false(shift_over(NULL))
  expect_false(shift_over(list(pending_hours = 8)))
  expect_false(shift_over(list(pending_hours = 0.5)))
  expect_true(shift_over(list(pending_hours = 0)))
  expect_true(shift_over(list(pending_hours = -1)))
  # Malformed payloads must not end the day by accident.
  expect_false(shift_over(list(pending_hours = NULL)))
  expect_false(shift_over(list(pending_hours = "soon")))
})

test_that("estado_set_finished folds the Experiment in without losing history", {
  estado <- init_estado(fake_session())
  # A DayState as the last /state or decision call returned it.
  estado_set_state(estado, list(
    experiment_id = "3f2504e0", status = "in_progress",
    next_trip = list(trip_id = 88455), pending_hours = 0,
    history = list(list(step = 0L, user = 0, policy = 0, baseline = 0),
                   list(step = 1L, user = 18.5, policy = 19.2, baseline = 12.1))
  ))

  exp <- list(
    id = "3f2504e0", status = "finished", company = "Uber",
    model_version = "0.0.1-data", seed = 42, seed_is_custom = TRUE,
    share_token = "aZ3kQ9mLp1Rt",
    result = list(final_user_wage = 2.31, outcome = "beat_model",
                  user_percentile = 62.5, trips_accepted = 1,
                  trips_rejected = 0, pct_following_policy = 100)
  )
  estado_set_finished(estado, exp)

  isolate({
    expect_equal(estado$status, "finished")
    expect_equal(estado$progress, 100L)
    expect_equal(estado$experiment$seed_is_custom, TRUE)
    expect_equal(estado$experiment$company, "Uber")
    expect_equal(estado$result$final_user_wage, 2.31)
    expect_equal(estado$share_token, "aZ3kQ9mLp1Rt")
    # The curves need this history, so /finish must not overwrite it.
    expect_equal(length(estado$state$history), 2)
    expect_equal(estado$state$status, "finished")
    expect_true(estado_ready(estado))
  })
})

test_that("estado_set_finished tolerates a NULL answer", {
  estado <- init_estado(fake_session())
  expect_null(estado_set_finished(estado, NULL))
  isolate(expect_null(estado$experiment))
})
