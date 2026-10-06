# The only two routes share knows (5.10). No network: httr2 is mocked, so
# this file tests parsing and error mapping rather than the API.

TOKEN <- "aZ3kQ9mLp1Rt"

json_response <- function(status, body) {
  httr2::response(status, body = charToRaw(body),
                  headers = list("content-type" = "application/json"))
}

fake_share_data <- function() {
  as.character(jsonlite::toJSON(list(
    day_label = "Day #aZ3kQ9", outcome = "beat_model",
    seed_is_custom = FALSE,
    final_user_wage = 27.4, final_policy_wage = 24.9, final_baseline_wage = 21.2,
    user_percentile = 73.5, pct_following_policy = 88,
    trips_accepted = 7L, trips_rejected = 3L,
    label = "I beat the Model!", share_text = "I beat the model today.",
    history = data.frame(step = 0:2, user = c(0, 10, 20), policy = c(0, 12, 24),
                         baseline = c(0, 8, 16))
  ), auto_unbox = TRUE, dataframe = "rows"))
}

ctx <- function(ip = "203.0.113.9") api_ctx(ip)

test_that("api_share_data sends the internal key and the client IP", {
  seen <- NULL
  res <- httr2::with_mocked_responses(
    function(req) { seen <<- req; json_response(200, fake_share_data()) },
    api_share_data(ctx("203.0.113.9"), TOKEN)
  )
  expect_equal(res$status, 200L)
  expect_equal(res$data$day_label, "Day #aZ3kQ9")
  expect_equal(res$data$user_percentile, 73.5)
  expect_equal(nrow(res$data$history), 3)
  expect_match(seen$url, paste0("/share-data/", TOKEN), fixed = TRUE)
  expect_equal(seen$headers[["X-Internal-Key"]], Sys.getenv("API_INTERNAL_KEY"))
  expect_equal(seen$headers[["X-Client-IP"]], "203.0.113.9")
})

test_that("the API answers 404 for a token nobody owns", {
  res <- httr2::with_mocked_responses(
    function(req) json_response(404, '{"error":"not_found","message":"Not found."}'),
    api_share_data(ctx(), TOKEN)
  )
  expect_equal(res$status, 404L)
  expect_null(res$data)
})

test_that("an unreachable API degrades to 503 instead of throwing", {
  res <- httr2::with_mocked_responses(
    function(req) stop("connection refused"),
    api_share_data(ctx(), TOKEN)
  )
  expect_equal(res$status, 503L)
  expect_null(res$data)
})

test_that("an empty client IP omits the X-Client-IP header", {
  seen <- NULL
  httr2::with_mocked_responses(
    function(req) { seen <<- req; json_response(404, '{"error":"not_found","message":"x"}') },
    api_share_data(api_ctx(""), TOKEN)
  )
  expect_false("X-Client-IP" %in% names(seen$headers))
})

test_that("api_waitlist relays the API message and the rate limit", {
  ok <- httr2::with_mocked_responses(
    function(req) json_response(200, '{"message":"You are on the waitlist."}'),
    api_waitlist(ctx(), "a@b.co")
  )
  expect_equal(ok$status, 200L)
  expect_match(ok$message, "waitlist")

  # Relayed, never retried: the per-IP limit (5.4) is the API's to enforce.
  limited <- httr2::with_mocked_responses(
    function(req) json_response(429, '{"error":"rate_limit_exceeded","message":"Wait a bit."}'),
    api_waitlist(ctx(), "a@b.co")
  )
  expect_equal(limited$status, 429L)
  expect_match(limited$message, "Wait a bit")
})

test_that("the base URL is configurable and never ends in a slash", {
  old <- Sys.getenv("TAXI_API_URL", unset = NA)
  on.exit(if (is.na(old)) Sys.unsetenv("TAXI_API_URL")
          else Sys.setenv(TAXI_API_URL = old))
  Sys.setenv(TAXI_API_URL = "http://api:8000///")
  expect_equal(api_ctx()$url, "http://api:8000")
  Sys.setenv(TAXI_API_URL = "")
  expect_equal(api_ctx()$url, "http://127.0.0.1:8000")
})
