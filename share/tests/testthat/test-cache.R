# Redis round-trip for the two things share stores: the view counters (7.4)
# and the render tally behind /metrics (ADR-0010 -- the PNG bytes are not
# stored any more). Skipped when Redis is not answering: the service must keep
# working without it.

TOKEN <- "aZ3kQ9mLp1Rt"
has_redis <- !is.null(redis_con())
skip_redis <- function() {
  if (!has_redis) skip("Redis is not reachable (docker compose up -d)")
}

test_that("the render tally counts up and has no expiry", {
  skip_redis()
  # The counter is global and survives every test run, so the only thing worth
  # asserting is that consecutive renders add one -- never an absolute value.
  first <- renders_incr()
  expect_true(is.integer(first) && !is.na(first))
  expect_identical(renders_incr(), first + 1L)
  expect_equal(as.integer(redis_con()$TTL("png:renders")), -1L)  # no EXPIRE
})

test_that("the view counter increments once per call and resets on demand", {
  skip_redis()
  views_del(TOKEN)
  on.exit(views_del(TOKEN), add = TRUE)
  expect_equal(views_incr(TOKEN), 1L)
  expect_equal(views_incr(TOKEN), 2L)
  expect_equal(views_get(TOKEN), 2L)
})

test_that("a Redis outage fails open instead of throwing", {
  old_port <- Sys.getenv("REDIS_PORT", unset = NA)
  on.exit(if (is.na(old_port)) Sys.unsetenv("REDIS_PORT")
          else Sys.setenv(REDIS_PORT = old_port), add = TRUE)
  Sys.setenv(REDIS_PORT = "6399")            # nothing listens here
  redis_forget()
  expect_null(renders_incr())
  expect_null(views_incr(TOKEN))
  redis_forget()                              # drop the failed connection
})
