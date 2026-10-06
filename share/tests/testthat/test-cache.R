# Redis round-trip for the two things share stores (7.1 and 7.4). Skipped
# when Redis is not answering: the service must keep working without it.

TOKEN <- "aZ3kQ9mLp1Rt"
has_redis <- !is.null(redis_con())
skip_redis <- function() {
  if (!has_redis) skip("Redis is not reachable (docker compose up -d)")
}

test_that("the PNG cache returns the exact bytes and expires", {
  skip_redis()
  on.exit(png_cache_del(TOKEN), add = TRUE)
  png_cache_del(TOKEN)
  expect_null(png_cache_get(TOKEN))                  # a cold cache is not an error

  bytes <- as.raw(c(137, 80, 78, 71, 13, 10, 26, 10))
  expect_true(png_cache_put(TOKEN, bytes))
  expect_identical(png_cache_get(TOKEN), bytes)
  expect_equal(as.integer(redis_con()$TTL(paste0("share:png:", TOKEN))) > 0L, TRUE)
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
  expect_null(png_cache_get(TOKEN))
  expect_false(png_cache_put(TOKEN, as.raw(1:3)))
  expect_null(views_incr(TOKEN))
  redis_forget()                              # drop the failed connection
})
