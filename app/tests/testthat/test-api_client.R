# The API client is tested against mocked HTTP responses (no server needed).
# Routes and payloads follow contract/openapi.yaml.

capture_request <- function(body = list(), status = 200L) {
  seen <- new.env()
  mock <- function(req) {
    seen$req <- req
    response_json(status_code = status, body = body)
  }
  list(seen = seen, mock = mock)
}

header_of <- function(req, name) {
  h <- req$headers[[name]]
  if (is.null(h)) return(NULL)
  if (is.list(h)) unlist(h, use.names = FALSE)[1] else as.character(h)[1]
}

ctx_for <- function(ip = "", resume_code = "") api_ctx(ip = ip, resume_code = resume_code)

test_that("api_validate_trip_start POSTs the start conditions", {
  cap <- capture_request(list(is_optimal = FALSE, better_company = "Uber",
                              better_datetime = "2024-05-12T20:00:00Z"))
  res <- with_mocked_responses(cap$mock,
    api_validate_trip_start(ctx_for(), "Lyft", "2024-05-12 00:00", 61))

  expect_match(cap$seen$req$url, "/validate-trip-start$")
  expect_false(res$is_optimal)
  expect_equal(res$better_company, "Uber")
})

test_that("api_recommend_start POSTs datetime and company", {
  cap <- capture_request(list(company = "Uber",
                               recommended_datetime = "2024-05-12T20:00:00Z",
                               hour = 20L, week_day = "saturday"))
  res <- with_mocked_responses(cap$mock,
    api_recommend_start(ctx_for(), "2024-05-12 00:00", "Lyft"))
  expect_match(cap$seen$req$url, "/recommend-start$")
  expect_equal(res$hour, 20L)
})

test_that("api_create_experiment omits empty seed/email and coerces the id", {
  cap <- capture_request(list(experiment_id = "abc", resume_code = "r",
                              share_token = "s", status = "setup"))
  with_mocked_responses(cap$mock,
    api_create_experiment(ctx_for(ip = "203.0.113.9"), "Uber",
                          "2024-05-12 20:00", 61,
                          seed = "", email = "  ", marketing_consent = FALSE))

  expect_match(cap$seen$req$url, "/experiments$")
  body <- cap$seen$req$body$data
  expect_equal(body$start_location_id, 61L)
  expect_false("seed" %in% names(body))
  expect_false("email" %in% names(body))
  expect_equal(header_of(cap$seen$req, "x-client-ip"), "203.0.113.9")
  expect_equal(header_of(cap$seen$req, "x-internal-key"),
               Sys.getenv("API_INTERNAL_KEY"))
})

test_that("api_decide sends trip_id, accepted and the resume code", {
  cap <- capture_request(list(experiment_id = "abc", status = "in_progress"))
  with_mocked_responses(cap$mock,
    api_decide(ctx_for(resume_code = "S3cret"), "abc", 88455, TRUE))

  expect_match(cap$seen$req$url, "/experiments/abc/decisions$")
  expect_equal(cap$seen$req$body$data$trip_id, 88455L)
  expect_true(cap$seen$req$body$data$accepted)
  expect_equal(header_of(cap$seen$req, "x-resume-code"), "S3cret")
})

test_that("api_get_state is a GET that carries the resume code", {
  cap <- capture_request(list(experiment_id = "abc", status = "in_progress"))
  with_mocked_responses(cap$mock,
    api_get_state(ctx_for(resume_code = "abc123"), "abc"))
  expect_match(cap$seen$req$url, "/experiments/abc/state$")
  expect_equal(header_of(cap$seen$req, "x-resume-code"), "abc123")
})

test_that("api_sensitivity drops empty zones and sets X-Device", {
  cap <- capture_request(list(recommendation = "accept"))
  with_mocked_responses(cap$mock,
    api_sensitivity(ctx_for(resume_code = "r"), "abc", 88455,
                    pickup_id = 132, dropoff_id = NULL, device = "mobile"))

  body <- cap$seen$req$body$data
  expect_equal(body$pickup_id, 132L)
  expect_false("dropoff_id" %in% names(body))
  expect_equal(header_of(cap$seen$req, "x-device"), "mobile")
  expect_equal(header_of(cap$seen$req, "x-resume-code"), "r")
})

test_that("API errors surface the message sent by the server", {
  m <- function(req) response_json(status_code = 422L,
                                   body = list(message = "location_id must be between 1 and 265."))
  expect_error(
    with_mocked_responses(m, api_validate_trip_start(ctx_for(), "Lyft",
                                                     "2024-05-12 00:00", 999)),
    "location_id must be between 1 and 265"
  )
})

test_that("the base URL comes from TAXI_API_URL", {
  old <- Sys.getenv("TAXI_API_URL", unset = NA)
  on.exit(if (is.na(old)) Sys.unsetenv("TAXI_API_URL")
          else Sys.setenv(TAXI_API_URL = old))
  Sys.setenv(TAXI_API_URL = "http://api.test:9999")

  cap <- capture_request(list())
  with_mocked_responses(cap$mock, api_recommend_start(ctx_for(),
                                                      "2024-05-12 00:00", "Lyft"))
  expect_match(cap$seen$req$url, "^http://api.test:9999/")
})

test_that("iso_8601 normalises what the setup form accepts", {
  expect_equal(iso_8601("2024-05-12 00:00"), "2024-05-12T00:00:00Z")
  expect_equal(iso_8601("2024-05-12T20:00:00Z"), "2024-05-12T20:00:00Z")
  expect_equal(iso_8601("2024-05-12"), "2024-05-12T00:00:00Z")
  # Not a date: pass it through and let the API answer 400.
  expect_equal(iso_8601("not a date"), "not a date")
  expect_equal(iso_8601(""), "")
})
