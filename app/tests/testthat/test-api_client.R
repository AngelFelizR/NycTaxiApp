# The API client is tested against mocked HTTP responses (no server needed).

mock_json <- function(body, status = 200L) {
  function(req) response_json(status_code = status, body = body)
}

capture_request <- function(body = list(), status = 200L) {
  seen <- new.env()
  mock <- function(req) {
    seen$req <- req
    response_json(status_code = status, body = body)
  }
  list(seen = seen, mock = mock)
}

test_that("api_options parses companies, zones and defaults", {
  m <- mock_json(list(companies = list("Lyft", "Uber"),
                      zones = list("Queens - Jamaica", "Queens - Saint Albans"),
                      default_start_dt = "2024-05-12 00:00"))
  res <- with_mocked_responses(m, api_options())
  expect_equal(res$companies, c("Lyft", "Uber"))
  expect_equal(res$zones, c("Queens - Jamaica", "Queens - Saint Albans"))
  expect_equal(res$default_start_dt, "2024-05-12 00:00")
})

test_that("api_validate POSTs the conditions to /validate", {
  cap <- capture_request(list(optimal = FALSE,
                              company_hint = "Use Uber for better results",
                              datetime_hint = "", message = ""))
  res <- with_mocked_responses(cap$mock,
    api_validate("Lyft", "2024-05-12 00:00", "Queens - Saint Albans"))

  expect_false(is.null(cap$seen$req$body))   # a JSON body makes httr2 use POST
  expect_match(cap$seen$req$url, "/validate$")
  expect_equal(cap$seen$req$body$data$company, "Lyft")
  expect_false(res$optimal)
  expect_true(has_hint(res$company_hint))
  expect_false(has_hint(res$datetime_hint))
})

test_that("api_create_day and api_decide hit the right routes", {
  cap <- capture_request(list(day_id = "abc123", finished = FALSE))
  with_mocked_responses(cap$mock,
    api_create_day("Uber", "2024-05-12 20:00", "Queens - Saint Albans"))
  expect_match(cap$seen$req$url, "/days$")

  cap <- capture_request(list(day_id = "abc123", finished = TRUE))
  res <- with_mocked_responses(cap$mock, api_decide("abc123", TRUE))
  expect_match(cap$seen$req$url, "/days/abc123/decisions$")
  expect_true(cap$seen$req$body$data$accept)
  expect_true(res$finished)
})

test_that("api_sensitivity drops NULL zones and returns a data frame", {
  cap <- capture_request(list(
    list(scenario = "Original", trip_minutes = 10, min_pay = 8),
    list(scenario = "Original", trip_minutes = 20, min_pay = 16)))
  res <- with_mocked_responses(cap$mock,
    api_sensitivity("abc123", pickup_zone = NULL, dropoff_zone = "Queens - Jamaica"))

  body <- cap$seen$req$body$data
  expect_false("pickup_zone" %in% names(body))
  expect_equal(body$dropoff_zone, "Queens - Jamaica")
  expect_s3_class(res, "data.frame")
  expect_named(res, c("scenario", "trip_minutes", "min_pay"))
})

test_that("API errors surface the message sent by the server", {
  m <- mock_json(list(message = "start_dt is not a valid date-time"), status = 422L)
  expect_error(
    with_mocked_responses(m, api_validate("Lyft", "nope", "Queens - Jamaica")),
    "start_dt is not a valid date-time"
  )
})

test_that("the base URL comes from TAXI_API_URL", {
  old <- Sys.getenv("TAXI_API_URL", unset = NA)
  on.exit(if (is.na(old)) Sys.unsetenv("TAXI_API_URL") else Sys.setenv(TAXI_API_URL = old))
  Sys.setenv(TAXI_API_URL = "http://api.test:9999")

  cap <- capture_request(list())
  with_mocked_responses(cap$mock, api_options())
  expect_match(cap$seen$req$url, "^http://api.test:9999/options$")
})
