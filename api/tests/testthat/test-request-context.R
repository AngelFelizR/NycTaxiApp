# Section 11's structured request log, unit by unit.
#
# The log itself is checked end to end by the flow that produced it (see the
# DIAG lines in app/tests/testthat/test-shinytest2.R and the notes in
# AGENTS); what was never checked was the middleware: what it attaches to the
# request, what it does when auth is the other half of the same hook, and
# whether the line it prints really carries the six fields and no address.

# Two streams, two sinks: access_logger writes the JSON to stderr while
# plumber2's console logger writes conditions to stdout.
capture_log <- function(expr) {
  out_con <- textConnection("stdout_lines", "w", local = TRUE)
  err_con <- textConnection("stderr_lines", "w", local = TRUE)
  sink(out_con, type = "output")
  sink(err_con, type = "message")
  # One cleanup path only: unsinking twice warns ("no sink to remove") and
  # a warning inside a test is noise the next reader has to discount.
  sunk <- TRUE
  on.exit(if (sunk) { sink(type = "message"); sink(type = "output") }, add = TRUE)
  force(expr)
  sink(type = "message")
  sink(type = "output")
  sunk <- FALSE
  captured <- c(stdout_lines, stderr_lines)
  close(out_con); close(err_con)
  paste(captured, collapse = "\n")
}

# An environment, not a list: plumber2's Request is mutable, and
# attach_request_context() writes `log_method` and friends onto it. A list
# would silently discard every assignment (copy-on-modify), which is exactly
# how this test first reported NULL for everything.
request_with <- function(...) {
  h <- list(...)
  e <- new.env(parent = emptyenv())
  e$method <- "get"
  e$path <- "/experiments"
  e$querystring <- "?a=1"
  e$get_header <- function(name) h[[tolower(name)]]
  e
}

test_that("attach_request_context records what only the request knows", {
  req <- request_with()
  attach_request_context(req)

  expect_identical(req$log_method, "GET")
  expect_identical(req$log_path, "/experiments?a=1")
  # Generated, not read: r + digits, never random(), because two requests in
  # the same microsecond must not share an id.
  expect_match(req$correlation_id, "^r[0-9]+$")
  # Section 4.3: a hash of a salted string, never the address itself.
  expect_match(req$ip_hash, "^[0-9a-f]{64}$")
  expect_false(grepl("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", req$ip_hash))
  expect_true(inherits(req$log_start, "POSIXct"))

  # An id supplied by the edge wins, trimmed.
  with_id <- request_with(`x-request-id` = "  edge-id-7  ")
  attach_request_context(with_id)
  expect_identical(with_id$correlation_id, "edge-id-7")

  # An empty header is not an id: the generator still has to run, or the
  # logger would print "" and two requests would be indistinguishable.
  empty_id <- request_with(`x-request-id` = "")
  attach_request_context(empty_id)
  expect_match(empty_id$correlation_id, "^r[0-9]+$")

  # A method the router has not filled in yet must not stop the attach.
  no_method <- new.env(parent = emptyenv())
  no_method$get_header <- function(name) NULL
  expect_silent(attach_request_context(no_method))
  expect_identical(no_method$log_method, "")
})

test_that("request_context attaches the log AND still decides authentication", {
  # No key: the auth half runs and is what the caller sees.
  res <- fake_response()
  request_context(fake_request(list()), res)
  expect_identical(res$status, 403L)
  expect_match(res$body$message, "X-Internal-Key")

  # A key that does not match: same decision, and the attach already happened.
  res <- fake_response()
  request_context(fake_request(list("x-internal-key" = "wrong")), res)
  expect_identical(res$status, 403L)

  # A failure inside the attach half must never become an authentication
  # failure: the two share one catch-all, so a logging error would otherwise
  # either open the API or take auth down with it. Only the header the logger
  # needs explodes; auth reads a different one.
  half_exploding <- list(get_header = function(name) {
    if (identical(tolower(name), "x-client-ip")) stop("boom")
    NULL
  })
  res <- fake_response()
  expect_error(suppressMessages(request_context(half_exploding, res)), NA)
  expect_identical(res$status, 403L)
})

test_that("status_from_access_log takes the number and defaults to 200", {
  expect_identical(status_from_access_log("STATUS=404"), 404L)
  expect_identical(status_from_access_log("STATUS=200"), 200L)
  expect_identical(status_from_access_log("something else"), 200L)
  expect_identical(status_from_access_log(""), 200L)
})

test_that("access_logger prints one JSON line with exactly the six fields", {
  req <- request_with()
  attach_request_context(req)

  out <- capture_log(
    access_logger("request", "STATUS=404", request = req)
  )
  expect_identical(length(strsplit(out, "\n", fixed = TRUE)[[1]]), 1L)

  line <- jsonlite::fromJSON(out)
  expect_named(
    line,
    c("method", "path", "status", "duration_ms", "correlation_id", "ip_hash")
  )
  expect_identical(line$method, "GET")
  expect_identical(line$path, "/experiments?a=1")
  expect_identical(line$status, 404L)
  expect_true(is.numeric(line$duration_ms) && line$duration_ms >= 0)
  expect_identical(line$correlation_id, req$correlation_id)
  expect_identical(line$ip_hash, req$ip_hash)

  # Section 11 says no clear IP anywhere in the line: a header that happens to
  # be an address must come out hashed, not verbatim.
  with_ip <- request_with(`x-client-ip` = "203.0.113.9")
  attach_request_context(with_ip)
  out <- capture_log(access_logger("request", "STATUS=200", request = with_ip))
  expect_false(grepl("203.0.113.9", out, fixed = TRUE))
  expect_match(out, '"ip_hash":"[0-9a-f]{64}"')

  # A request that never got a context still logs, with NA duration rather
  # than a crash -- the guard is what keeps a missing attach survivable.
  bare <- new.env(parent = emptyenv())
  bare$get_header <- function(n) NULL
  out <- capture_log(access_logger("request", "STATUS=500", request = bare))
  # A missing start cannot be a number, and the key has to be present either
  # way so consumers never see it silently disappear. The line carries a
  # JSON null -- toJSON's default would have made it the *string* "NA", which
  # is what access_logger now passes na = "null" to avoid.
  expect_null(jsonlite::fromJSON(out)$duration_ms)
})

test_that("access_logger leaves every other event to the console logger", {
  # Conditions and warnings arrive as events other than "request"; they must
  # not be swallowed and must not be turned into a JSON line.
  out <- capture_log(
    access_logger("condition", "something happened", request = NULL)
  )
  expect_false(grepl('"method"', out, fixed = TRUE))
  expect_match(out, "something happened")
})
