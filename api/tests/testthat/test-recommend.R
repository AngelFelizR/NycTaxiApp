# Synthetic ValidHoursToStartWorking table: cycles are
# (wday - 1) * 24 + hour with wday 1 = Sunday, so 17/18 are
# Sunday 17:00 and Sunday 18:00.
valid_hours_fixture <- function() {
  data.frame(week_cycle = c(17L, 18L))
}

test_that("next_valid_start picks the next strictly greater cycle", {
  vh <- valid_hours_fixture()
  sunday16 <- as.POSIXct("2025-01-05 16:00:00", tz = "UTC")
  expect_identical(
    next_valid_start(vh, sunday16),
    as.POSIXct("2025-01-05 17:00:00", tz = "UTC")
  )
  # Equal cycle is not "next": strictly greater, so 18:00 -> week wrap.
  sunday1830 <- as.POSIXct("2025-01-05 18:30:00", tz = "UTC")
  expect_identical(
    next_valid_start(vh, sunday1830),
    as.POSIXct("2025-01-12 17:00:00", tz = "UTC")
  )
  # Mid-week input wraps with the +168h copy of the table.
  monday10 <- as.POSIXct("2025-01-06 10:00:00", tz = "UTC")
  expect_identical(
    next_valid_start(vh, monday10),
    as.POSIXct("2025-01-12 17:00:00", tz = "UTC")
  )
})

test_that("next_valid_start guards empty inputs", {
  expect_true(is.na(next_valid_start(NULL, Sys.time())))
  expect_true(is.na(
    next_valid_start(data.frame(week_cycle = integer(0)), Sys.time())
  ))
})

test_that("recommend_start_body exposes the contract fields", {
  body <- recommend_start_body(
    valid_hours_fixture(),
    as.POSIXct("2025-01-05 16:00:00", tz = "UTC")
  )
  expect_identical(
    names(body),
    c("company", "recommended_datetime", "hour", "week_day")
  )
  expect_null(body$company) # filled by the endpoint
  expect_identical(body$recommended_datetime, "2025-01-05T17:00:00Z")
  expect_identical(body$hour, 17L)
  expect_identical(body$week_day, "sunday")
})
