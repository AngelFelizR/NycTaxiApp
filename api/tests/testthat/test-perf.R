test_that("memoize_binding caches by arguments and keeps the wrapper flag", {
  env <- new.env(parent = emptyenv())
  calls <- 0L
  env$f <- function(x) {
    calls <<- calls + 1L
    x * 2
  }
  expect_true(memoize_binding("f", env))
  expect_identical(env$f(21), 42)
  expect_identical(env$f(21), 42)
  expect_identical(calls, 1L) # second call served from the cache
  expect_identical(env$f(22), 44)
  expect_identical(calls, 2L) # different arguments recompute
  # Idempotent: already wrapped bindings are left alone.
  expect_false(memoize_binding("f", env))
  expect_false(memoize_binding("missing", env))
})

test_that("install_time_speedups is idempotent and returns a count", {
  n1 <- install_time_speedups()
  expect_true(is.numeric(n1) && n1 >= 1)
  n2 <- install_time_speedups()
  expect_identical(n2, 0L)
})

test_that("fast bake methods are equivalent to the recipes originals", {
  skip_if_not_installed("dplyr")
  df <- data.frame(
    a = c(1, NA, 3, 100),
    b = c("p", "q", "q", "r"),
    d = c(10, 20, NA, 40),
    stringsAsFactors = FALSE
  )
  rec <- recipes::recipe(~ ., data = df) |>
    recipes::step_rename(renamed_a = a) |>
    recipes::step_impute_median(recipes::all_numeric_predictors()) |>
    recipes::prep()

  # Capture the originals before install_bake_speedups() swaps the ns binding.
  orig_impute <- getFromNamespace("bake.step_impute_median", "recipes")
  orig_rename <- getFromNamespace("bake.step_rename", "recipes")
  new_data <- tibble::as_tibble(df)

  step_impute <- rec$steps[[2]]
  step_rename <- rec$steps[[1]]
  # The impute step was prepped on the renamed columns, so feed it the data
  # the way bake.recipe would: rename first, then impute.
  renamed <- bake_rename_fast(step_rename, new_data)
  expect_identical(
    bake_impute_median_fast(step_impute, renamed),
    orig_impute(step_impute, renamed)
  )
  expect_identical(
    bake_rename_fast(step_rename, new_data),
    orig_rename(step_rename, new_data)
  )

  before <- recipes::bake(rec, new_data)
  expect_identical(install_bake_speedups(), 2L)
  after <- recipes::bake(rec, new_data)
  expect_identical(after, before)
  expect_identical(names(after), c("renamed_a", "b", "d"))
  expect_identical(after$renamed_a, c(1, 3, 3, 100))
  expect_identical(after$d, c(10, 20, 20, 40))

  # Dispatch inside bake.recipe goes through the replaced namespace binding.
  expect_identical(
    getS3method("bake", "step_impute_median"),
    bake_impute_median_fast
  )
  expect_identical(
    getS3method("bake", "step_rename"),
    bake_rename_fast
  )
})
