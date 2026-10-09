test_that("load_dotenv treats a blank value as unset, not as empty", {
  # Same rule as api/R/utils.R, and it matters here: share/plumber.R coerces
  # SHARE_PORT with as.integer(), and as.integer("") is NA -- a blank line in
  # .env.example used to make the service refuse to start on a fresh clone.
  path <- tempfile(fileext = ".env")
  writeLines(c("BLANK_FROM_SHARE_ENV=", "FILLED_FROM_SHARE_ENV=hello"), path)
  on.exit({
    unlink(path)
    Sys.unsetenv("BLANK_FROM_SHARE_ENV")
    Sys.unsetenv("FILLED_FROM_SHARE_ENV")
  }, add = TRUE)
  Sys.unsetenv("BLANK_FROM_SHARE_ENV")
  Sys.unsetenv("FILLED_FROM_SHARE_ENV")
  expect_true(load_dotenv(path))
  expect_identical(Sys.getenv("BLANK_FROM_SHARE_ENV", unset = NA_character_),
                   NA_character_, label = "blank line left the variable unset")
  expect_identical(Sys.getenv("FILLED_FROM_SHARE_ENV"), "hello")
})
