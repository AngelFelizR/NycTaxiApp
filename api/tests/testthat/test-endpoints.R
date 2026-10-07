ct <- list("content-type" = "application/json")

test_that("predict_handler rejects without models and validates the payload", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)

  set_model_state()
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(list()))
  expect_identical(response$status, 503L)
  expect_identical(response$body$error, "service_unavailable")

  set_model_state(policy_name = "fake")
  full <- list(
    pulocation_id = 61, dolocation_id = 230, trip_miles = 2.5,
    trip_time_sec = 1500, driver_pay = 28.5,
    request_datetime = "2025-01-06T08:30:00Z"
  )

  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(list(pulocation_id = 1)))
  expect_identical(response$status, 400L)
  expect_match(response$body$message, "dolocation_id")

  bad_zone <- full
  bad_zone$pulocation_id <- 0
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(bad_zone))
  expect_identical(response$status, 422L)

  bad_zone <- full
  bad_zone$pulocation_id <- 1.5
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(bad_zone))
  expect_identical(response$status, 400L)
  expect_match(response$body$message, "integers")

  bad_pay <- full
  bad_pay$driver_pay <- -1
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(bad_pay))
  expect_identical(response$status, 422L)

  bad_time <- full
  bad_time$request_datetime <- "not-a-date"
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(bad_time))
  expect_identical(response$status, 400L)

  bad_company <- full
  bad_company$company <- "Via"
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(bad_company))
  expect_identical(response$status, 400L)

  response <- fake_response()
  predict_handler(fake_request(list()), response, json_raw(full))
  expect_identical(response$status, 400L)
  expect_match(response$body$message, "Content-Type")

  response <- fake_response()
  predict_handler(fake_request(ct), response, charToRaw("{oops"))
  expect_identical(response$status, 400L)
})

test_that("predict_handler maps the payload onto the policy frame", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)
  set_model_state(policy_name = "fake")

  captured <- NULL
  local_mocked_bindings(
    policy_probability = function(frame) {
      captured <<- frame
      0.941
    },
    .package = "taxiapi"
  )

  payload <- list(
    pulocation_id = 61, dolocation_id = 230, trip_miles = 2.5,
    trip_time_sec = 1500, driver_pay = 28.5,
    request_datetime = "2025-01-06T08:30:00Z", company = "Lyft"
  )
  response <- fake_response()
  res <- predict_handler(fake_request(ct), response, json_raw(payload))
  expect_s3_class(res, "plumber_control")
  expect_identical(response$body, list(accepted = TRUE, probability = 0.941))
  expect_identical(captured$PULocationID, "61")
  expect_identical(captured$DOLocationID, "230")
  expect_identical(captured$hvfhs_license_num, "HV0005") # company -> hvfhs
  expect_equal(captured$trip_time, 1500) # int or double, depends on JSON parse
  expect_equal(captured$trip_miles, 2.5)
  expect_true(is.na(captured$performance_per_hour))
  expect_true(is.na(captured$percentile_75_performance))
  expect_s3_class(captured$request_datetime, "POSIXct")

  # Strictly greater than 0.90 (contract): exactly 0.90 is rejected.
  local_mocked_bindings(policy_probability = function(frame) 0.90,
                        .package = "taxiapi")
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(payload))
  expect_identical(response$body, list(accepted = FALSE, probability = 0.90))
})

test_that("predict_handler reports model failures as 500", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)
  set_model_state(policy_name = "fake")

  local_mocked_bindings(policy_probability = function(frame) NA_real_,
                        .package = "taxiapi")

  payload <- list(
    pulocation_id = 61, dolocation_id = 230, trip_miles = 2.5,
    trip_time_sec = 1500, driver_pay = 28.5,
    request_datetime = "2025-01-06T08:30:00Z"
  )
  response <- fake_response()
  predict_handler(fake_request(ct), response, json_raw(payload))
  expect_identical(response$status, 500L)
  expect_identical(response$body$error, "internal_error")
})

test_that("recommend_start_handler looks up the next valid start", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)

  set_model_state()
  response <- fake_response()
  recommend_start_handler(fake_request(ct), response, json_raw(list()))
  expect_identical(response$status, 503L)

  set_model_state(valid_hours = data.frame(week_cycle = c(17L, 18L)))
  response <- fake_response()
  res <- recommend_start_handler(
    fake_request(ct), response,
    json_raw(list(company = "Uber", datetime = "2025-01-05T16:00:00Z"))
  )
  expect_s3_class(res, "plumber_control")
  expect_identical(
    response$body,
    list(
      company = "Uber",
      recommended_datetime = "2025-01-05T17:00:00Z",
      hour = 17L,
      week_day = "sunday"
    )
  )

  response <- fake_response()
  recommend_start_handler(
    fake_request(ct), response,
    json_raw(list(company = "Via", datetime = "2025-01-05T16:00:00Z"))
  )
  expect_identical(response$status, 400L)

  response <- fake_response()
  recommend_start_handler(
    fake_request(ct), response,
    json_raw(list(company = "Uber"))
  )
  expect_identical(response$status, 400L)
  expect_match(response$body$message, "datetime")
})

test_that("validate-trip-start returns the optimal / better variants", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)

  set_model_state()
  response <- fake_response()
  validate_trip_start_handler(fake_request(ct), response, json_raw(list()))
  expect_identical(response$status, 503L)

  set_model_state(
    tree = structure(list(), class = "fake_tree"),
    valid_hours = data.frame(week_cycle = c(17L, 18L))
  )
  payload <- list(
    company = "Uber", datetime = "2025-01-05T16:00:00Z", location_id = 61
  )
  # Optimal start: better_* fields are omitted entirely (not null).
  local_mocked_bindings(start_is_high_value = function(...) TRUE,
                        .package = "taxiapi")
  response <- fake_response()
  res <- validate_trip_start_handler(fake_request(ct), response, json_raw(payload))
  expect_s3_class(res, "plumber_control")
  expect_identical(response$body, list(is_optimal = TRUE))

  # Not optimal, Uber better now: same datetime is the recommendation.
  # (The candidate must not be Uber itself, otherwise the first call would
  # already be optimal.)
  lyft_payload <- modifyList(payload, list(company = "Lyft"))
  local_mocked_bindings(
    start_is_high_value = function(company, datetime, location_id)
      identical(company, "Uber"),
    .package = "taxiapi"
  )
  response <- fake_response()
  validate_trip_start_handler(fake_request(ct), response, json_raw(lyft_payload))
  expect_identical(response$body$is_optimal, FALSE)
  expect_identical(response$body$better_company, "Uber")
  expect_identical(response$body$better_datetime, "2025-01-05T16:00:00Z")

  # Not optimal anywhere: next valid start from the lookup table.
  local_mocked_bindings(start_is_high_value = function(...) FALSE,
                        .package = "taxiapi")
  response <- fake_response()
  validate_trip_start_handler(fake_request(ct), response, json_raw(payload))
  expect_identical(response$body$is_optimal, FALSE)
  expect_identical(response$body$better_datetime, "2025-01-05T17:00:00Z")

  # Validation errors still precede the model call.
  response <- fake_response()
  validate_trip_start_handler(
    fake_request(ct), response,
    json_raw(list(
      company = "Uber", datetime = "2025-01-05T16:00:00Z",
      location_id = 0
    ))
  )
  expect_identical(response$status, 422L)
})

test_that("not_found_handler turns an empty body into the contract 404", {
  response <- fake_response()
  response$body <- ""
  res <- not_found_handler(fake_request(), response)
  expect_s3_class(res, "plumber_control")
  expect_identical(response$status, 404L)
  expect_identical(
    response$body,
    list(error = "not_found", message = "No route matches.")
  )

  # A matched route already stored a body: leave it alone.
  response <- fake_response()
  response$body <- list(ok = TRUE)
  not_found_handler(fake_request(), response)
  expect_null(response$status)
  expect_identical(response$body, list(ok = TRUE))
})

test_that("health_handler reports 503 when the pool or models are missing", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)

  set_model_state() # nothing loaded, no pool
  response <- fake_response()
  health_handler(response)
  expect_identical(response$status, 503L)
  expect_identical(response$body$status, "unavailable")
  expect_identical(response$body$database$status, "error")

  set_model_state(policy_name = "p", tree = "t", valid_hours = "v")
  response <- fake_response()
  health_handler(response)
  expect_identical(response$status, 503L) # database still down
  expect_true(response$body$models$policy)
  expect_true(response$body$models$start_validator)
  expect_true(response$body$models$valid_hours)
})
