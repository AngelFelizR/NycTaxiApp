# Per-IP daily rate limits (section 5.4): Redis counters with a sliding
# expiry at midnight UTC, and fail-closed behaviour when Redis is down.

random_ip <- function() {
  sprintf("10.%d.%d.%d", sample.int(200, 1) + 10, sample.int(255, 1),
          sample.int(254, 1) + 1)
}

with_redis <- function(code) {
  skip_if_not(redis_available(), "Redis is not reachable")
  force(code)
}

drop_keys <- function(keys) {
  con <- redis_con()
  if (is.null(con)) return(invisible(FALSE))
  try(con$DEL(keys), silent = TRUE)
  invisible(TRUE)
}

test_that("rate_limit_check allows up to the limit and then answers 429", {
  with_redis({
    ip <- random_ip()
    request <- fake_request(list("x-client-ip" = ip))
    key <- rate_limit_key("exp", client_ip_hash(request))
    on.exit(drop_keys(key), add = TRUE)

    for (i in seq_len(3)) {
      response <- fake_response()
      expect_null(rate_limit_check(request, response, "exp", 3L, "too many"))
      expect_identical(response$headers[["x-ratelimit-limit"]], "3")
      expect_identical(
        response$headers[["x-ratelimit-remaining"]],
        as.character(3L - i)
      )
      expect_true(grepl("^[0-9]+$", response$headers[["x-ratelimit-reset"]]))
    }

    response <- fake_response()
    break_obj <- rate_limit_check(
      request, response, "exp", 3L,
      "You've reached the limit of 3 experiments per day."
    )
    expect_false(is.null(break_obj))
    expect_identical(response$status, 429L)
    expect_identical(response$body$error, "rate_limit_exceeded")
    expect_match(response$body$message, "3 experiments per day")
    expect_true(grepl("^[0-9]+$", response$headers[["retry-after"]]))
    expect_identical(response$headers[["x-ratelimit-remaining"]], "0")
  })
})

test_that("a missing X-Client-IP shares the literal unknown bucket", {
  with_redis({
    request <- fake_request(list())
    expect_identical(client_ip_value(request), "unknown")
    key <- rate_limit_key("waitlist", client_ip_hash(request))
    on.exit(drop_keys(key), add = TRUE)
    drop_keys(key)

    for (i in seq_len(5)) {
      response <- fake_response()
      expect_null(rate_limit_check(request, response, "waitlist", 5L, "x"))
    }
    response <- fake_response()
    rate_limit_check(request, response, "waitlist", 5L, "x")
    expect_identical(response$status, 429L)
  })
})

test_that("the limit fails closed when Redis is down", {
  local_mocked_bindings(redis_incr = function(key, ttl = 86400L) NULL,
                        .package = "taxiapi")

  response <- fake_response()
  rate_limit_check(fake_request(list("x-client-ip" = "10.0.0.1")), response,
                   "exp", 3L, "x")
  expect_identical(response$status, 503L)
  expect_identical(response$body$error, "service_unavailable")
})

test_that("the counter key carries the UTC day", {
  expect_identical(
    rate_limit_key("exp", "abc"),
    sprintf("exp:ip:abc:%s", format(Sys.Date(), "%Y%m%d"))
  )
  reset <- seconds_until_midnight_utc()
  expect_true(reset >= 0 && reset <= 86400)
})
