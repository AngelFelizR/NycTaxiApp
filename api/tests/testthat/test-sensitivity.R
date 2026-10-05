# /sensitivity (phase 2): planted trip/zone data + a mocked policy_probability
# keep these tests hermetic (no parquet, no model); Redis-backed cache tests
# skip when Redis is unreachable. Real timings live in api/dev/smoke.sh.

ct <- list("content-type" = "application/json")
cid <- list("content-type" = "application/json", "x-client-ip" = "1.2.3.4")

plant_trip_data <- function() {
  data_state$ready <- TRUE
  data_state$trips <- data.frame(
    trip_id = c(100, 200, 300),
    hvfhs_license_num = c("HV0003", "HV0005", "HV0003"),
    request_datetime = as.POSIXct(
      c("2024-05-12 08:00:00", "2024-05-13 09:00:00", "2024-05-14 10:00:00"),
      tz = "UTC"
    ),
    PULocationID = c(61L, 132L, 161L),
    DOLocationID = c(161L, 230L, 45L),
    trip_miles = c(11.2, 5, 2),
    trip_time = c(2071, 900, 600),
    tips = c(0, 1, 2),
    driver_pay = c(35.35, 20, 10),
    stringsAsFactors = FALSE
  )
  data_state$zones <- data.frame(
    LocationID = c(13L, 45L, 61L, 132L, 144L, 161L, 201L, 230L),
    borough = c(
      "Manhattan", "Manhattan", "Brooklyn", "Queens",
      "Manhattan", "Manhattan", "Bronx", "Manhattan"
    ),
    zone = c(
      "Battery Park City", "Chinatown", "Crown Heights North", "JFK Airport",
      "Little Italy/NoLiTa", "Midtown Center", "Test Bronx Zone",
      "Times Sq/Theatre District"
    ),
    stringsAsFactors = FALSE
  )
  invisible(TRUE)
}

# Deterministic stand-in for the fitted policy: pay drives the probability,
# zone 144 (pickup) and zone 45 (drop-off) shift it the most, so the
# auto-selection is easy to assert.
mock_policy_probability <- function(frame) {
  p <- frame$driver_pay / 40
  p <- p + ifelse(frame$PULocationID == "144", 0.3, 0)
  p <- p + ifelse(frame$DOLocationID == "45", 0.25, 0)
  pmin(0.99, pmax(0.01, p))
}

with_mocked_policy <- function(code) {
  orig <- policy_probability
  assign("policy_probability", mock_policy_probability, envir = globalenv())
  on.exit(assign("policy_probability", orig, envir = globalenv()), add = TRUE)
  force(code)
}

sens_payload <- function(...) {
  # Merge overrides after the defaults: list(a = 1, a = 2) would keep the
  # first value and quietly defeat the override.
  out <- list(
    experiment_id = "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
    trip_id = 200
  )
  extra <- list(...)
  for (nm in names(extra)) out[[nm]] <- extra[[nm]]
  out
}

run_sensitivity <- function(payload, headers = cid) {
  response <- fake_response()
  sensitivity_handler(
    fake_request(headers), response,
    json_raw(payload)
  )
  response
}

test_that("trip and zone helpers work on planted data", {
  plant_trip_data()
  on.exit({ data_state$ready <- FALSE }, add = TRUE)

  expect_true(trip_data_ready())
  trip <- trip_row(200)
  expect_s3_class(trip, "data.frame")
  expect_identical(trip$PULocationID, 132L)
  expect_null(trip_row(999))

  expect_identical(zone_info(132)$zone, "JFK Airport")
  expect_null(zone_info(999))
  expect_identical(zone_label(132), "(132) Queens - JFK Airport")
  expect_identical(zone_label(999), "(999)")

  candidates <- sensitivity_zone_candidates(61L)
  expect_false(61L %in% candidates)
  expect_false(201L %in% candidates) # Bronx is out of the prototype subset
  expect_true(all(c(13L, 45L, 132L, 144L, 161L, 230L) %in% candidates))
})

test_that("select_zone_with_high_change picks the hardest zone", {
  plant_trip_data()
  on.exit({ data_state$ready <- FALSE }, add = TRUE)
  with_mocked_policy({
    base <- sensitivity_base_frame(trip_row(100)) # PU 61 / DO 161
    expect_identical(
      select_zone_with_high_change(
        base, sensitivity_zone_candidates(61L), "PULocationID"
      ),
      144L
    )
    expect_identical(
      select_zone_with_high_change(
        base, sensitivity_zone_candidates(161L), "DOLocationID"
      ),
      45L
    )
  })
})

test_that("compute_decision_grid returns three aligned grids", {
  plant_trip_data()
  on.exit({ data_state$ready <- FALSE }, add = TRUE)
  with_mocked_policy({
    base <- sensitivity_base_frame(trip_row(100))
    grids <- compute_decision_grid(base, pu_zone = 144L, do_zone = 45L, grid_len = 10)

    expect_named(grids, c("original", "pu", "do"))
    for (g in grids) {
      expect_s3_class(g, "data.frame")
      expect_identical(nrow(g), 100L)
      expect_identical(names(g), c("trip_time_sec", "driver_pay", "prob"))
      expect_true(is.integer(g$trip_time_sec))
      expect_true(all(g$prob >= 0 & g$prob <= 1))
    }
    # Same axes for the three scenarios; changed zones change the probability.
    expect_identical(grids$original$trip_time_sec, grids$pu$trip_time_sec)
    expect_identical(grids$original$driver_pay, grids$pu$driver_pay)
    expect_false(isTRUE(all.equal(grids$original$prob, grids$pu$prob)))
    expect_false(isTRUE(all.equal(grids$original$prob, grids$do$prob)))
    # Trip exceeds neither axis cap: full prototype window (2500s, $65).
    expect_identical(range(grids$original$trip_time_sec), c(0L, 2500L))
  })
})

test_that("sensitivity_handler validates headers, payload and models", {
  plant_trip_data()
  old <- snapshot_model_state()
  on.exit({
    data_state$ready <- FALSE
    restore_model_state(old)
  }, add = TRUE)
  set_model_state(policy_name = "fake")

  # Models down first (checked before everything else).
  set_model_state()
  response <- run_sensitivity(sens_payload())
  expect_identical(response$status, 503L)
  set_model_state(policy_name = "fake")

  expect_identical(run_sensitivity(sens_payload(), headers = ct)$status, 400L)
  expect_match(run_sensitivity(sens_payload(), headers = ct)$body$message, "X-Client-IP")

  bad_device <- run_sensitivity(
    sens_payload(), headers = c(cid, list("x-device" = "watch"))
  )
  expect_identical(bad_device$status, 400L)

  expect_match(run_sensitivity(list(trip_id = 200))$body$message, "experiment_id")
  expect_match(
    run_sensitivity(sens_payload(experiment_id = "not-a-uuid"))$body$message,
    "UUID"
  )
  expect_match(
    run_sensitivity(sens_payload(trip_id = "abc"))$body$message,
    "trip_id"
  )
  expect_identical(run_sensitivity(sens_payload(trip_id = 999))$status, 404L)

  expect_match(
    run_sensitivity(sens_payload(pickup_id = 1.5))$body$message, "pickup_id"
  )
  expect_identical(
    run_sensitivity(sens_payload(dropoff_id = 0))$status, 422L
  )
  expect_identical(
    run_sensitivity(sens_payload(grid_size = 5))$status, 422L
  )
  expect_match(
    run_sensitivity(sens_payload(grid_size = "big"))$body$message, "grid_size"
  )
})

test_that("sensitivity_handler builds the contract response", {
  plant_trip_data()
  old <- snapshot_model_state()
  on.exit({
    data_state$ready <- FALSE
    restore_model_state(old)
  }, add = TRUE)
  set_model_state(policy_name = "fake")
  with_mocked_policy({
    # Auto zones (mock: PU -> 144, DO -> 45), small grid for speed.
    response <- run_sensitivity(sens_payload(grid_size = 10))
    expect_null(response$status) # success leaves the plumber2 default (200)
    res <- response$body
    expect_true(res$recommendation %in% c("accept", "reject"))
    expect_identical(res$pickup_suggested, 144L)
    expect_identical(res$dropoff_suggested, 45L)
    expect_identical(res$meta$threshold, 0.9)
    expect_identical(
      res$meta$original_label,
      "PU (132) Queens - JFK Airport / DO (230) Manhattan - Times Sq/Theatre District"
    )
    expect_identical(res$meta$pu_label, "(144) Manhattan - Little Italy/NoLiTa")
    expect_match(res$meta$subtitle_html, "^<b>Original:</b> PU ")
    expect_identical(res$meta$original_point$trip_time_sec, 900L)
    expect_identical(nrow(res$grid_original), 100L)
    expect_identical(nrow(res$grid_pu), 100L)
    expect_identical(nrow(res$grid_do), 100L)

    # Explicit zones: grids use them, suggestions are null.
    response <- run_sensitivity(
      sens_payload(pickup_id = 132, dropoff_id = 144, grid_size = 10)
    )
    expect_null(response$status)
    expect_true(is.na(response$body$pickup_suggested))
    expect_true(is.na(response$body$dropoff_suggested))
    expect_identical(response$body$meta$pu_label, "(132) Queens - JFK Airport")

    # X-Device: mobile wins over grid_size.
    response <- run_sensitivity(
      sens_payload(grid_size = 10), headers = c(cid, list("x-device" = "mobile"))
    )
    expect_null(response$status)
    expect_identical(nrow(response$body$grid_original), 900L)
  })
})

test_that("sensitivity responses survive the Redis cache unchanged", {
  skip_if_not(redis_available(), "Redis not reachable")
  plant_trip_data()
  old <- snapshot_model_state()
  on.exit({
    data_state$ready <- FALSE
    restore_model_state(old)
  }, add = TRUE)
  set_model_state(policy_name = "fake")
  with_mocked_policy({
    # Known key for trip 200 with auto zones (144/45): start from a clean slate.
    redis_con()$DEL(sprintf(
      "sens:%s:%s:%s:%s", sens_payload()$experiment_id, 200, 144, 45
    ))

    fresh <- run_sensitivity(sens_payload(grid_size = 10))
    expect_null(fresh$status)
    hit <- run_sensitivity(sens_payload(grid_size = 10))
    expect_null(hit$status)

    ser <- function(x) {
      jsonlite::toJSON(x, auto_unbox = TRUE, na = "null", digits = 4)
    }
    expect_identical(ser(fresh$body), ser(hit$body))

    # A mobile request must not be served by the 50x50 value under the same
    # key (the contract key has no grid slot; the wrapper guards it).
    mobile <- run_sensitivity(
      sens_payload(), headers = c(cid, list("x-device" = "mobile"))
    )
    expect_null(mobile$status)
    expect_identical(nrow(mobile$body$grid_original), 900L)
    again <- run_sensitivity(sens_payload(grid_size = 10))
    expect_identical(nrow(again$body$grid_original), 100L)
  })
})

test_that("the real parquet loads when the dataset is mounted", {
  skip_if_not(
    file.exists(file.path(data_dir(), "NycTrips2024_sample_week.parquet")),
    "dataset not mounted"
  )
  expect_true(load_trip_data())
  trip <- trip_row(87713555)
  expect_s3_class(trip, "data.frame")
  expect_identical(trip$PULocationID, 61L)
  expect_identical(trip$DOLocationID, 161L)
  expect_null(trip_row(1))
  expect_true(length(sensitivity_zone_candidates(trip$PULocationID)) >= 150)
})
