test_that("has_hint accepts only a single non-empty string", {
  expect_true(has_hint("Use Uber for better results"))
  expect_false(has_hint(""))
  expect_false(has_hint(NULL))
  expect_false(has_hint(c("a", "b")))
  expect_false(has_hint(1))
})

test_that("zone_or_null maps the '-' placeholder and NULL to NULL", {
  expect_null(zone_or_null("-"))
  expect_null(zone_or_null(NULL))
  expect_equal(zone_or_null("Queens - Jamaica"), "Queens - Jamaica")
})

test_that("line_plot builds a ggplot from the API history", {
  history <- data.frame(step = 0:3, user = c(0, 10, 25, 30),
                        policy = c(0, 12, 20, 33))
  expect_s3_class(line_plot(history, "user"), "ggplot")
  expect_s3_class(line_plot(history, "policy"), "ggplot")
})

test_that("basemap returns a leaflet widget", {
  expect_s3_class(basemap(), "leaflet")
})

test_that("validation_hints is silent when the start is optimal", {
  h <- validation_hints(list(is_optimal = TRUE), "Lyft", "2024-05-12 00:00")
  expect_equal(h$company_hint, "")
  expect_equal(h$datetime_hint, "")
  expect_equal(h$message, msg_perfect)
})

test_that("validation_hints names the better company and datetime", {
  h <- validation_hints(
    list(is_optimal = FALSE, better_company = "Uber",
         better_datetime = "2024-05-12T20:00:00Z"),
    company = "Lyft", datetime = "2024-05-12 00:00")
  expect_equal(h$company_hint, "Use Uber for better results")
  expect_match(h$datetime_hint, "2024-05-12T20:00:00Z")
})

test_that("validation_hints stays quiet about what the user already chose", {
  # Same datetime, different format only: nothing to suggest.
  h <- validation_hints(
    list(is_optimal = FALSE, better_company = "Uber",
         better_datetime = "2024-05-12T20:00:00Z"),
    company = "Uber", datetime = "2024-05-12 20:00")
  expect_equal(h$company_hint, "")
  expect_equal(h$datetime_hint, "")
})

test_that("validation_hints tolerates a NULL response", {
  h <- validation_hints(NULL, "Lyft", "2024-05-12 00:00")
  expect_equal(h, list(company_hint = "", datetime_hint = "", message = ""))
})

test_that("history_df accepts both shapes the API can serialise to", {
  rows <- history_df(list(
    list(step = 0, user = 0, policy = 0, baseline = 0),
    list(step = 1, user = 10, policy = 12, baseline = 8)
  ))
  expect_equal(nrow(rows), 2)
  expect_named(rows, c("step", "user", "policy", "baseline"))

  flat <- history_df(data.frame(step = 0:1, user = c(0, 10),
                                policy = c(0, 12), baseline = c(0, 8)))
  expect_equal(nrow(flat), 2)
  expect_equal(history_df(list()),
               data.frame(step = numeric(), user = numeric(),
                          policy = numeric(), baseline = numeric()))
})

test_that("grid_df flattens a sensitivity grid", {
  g <- grid_df(list(
    list(trip_time_sec = 600, driver_pay = 8.5, prob = 0.05),
    list(trip_time_sec = 1200, driver_pay = 17, prob = 0.42)
  ))
  expect_equal(nrow(g), 2)
  expect_named(g, c("trip_time_sec", "driver_pay", "prob"))
  expect_equal(grid_df(NULL), data.frame())
})

test_that("app_options preloads companies and zones from the data volume", {
  skip_if_not(file.exists(file.path(app_data_dir(), "ZonesShapes.qs2")),
              "zone shapes are not mounted")
  o <- app_options()
  expect_equal(o$companies, c("Lyft", "Uber"))
  expect_gt(length(o$zones), 100)
  # values are LocationIDs, labels are "borough - zone"
  expect_true(any(grepl(" - ", names(o$zones))))
  expect_type(o$zones, "integer")
})

test_that("app_data_dir falls back to a path that exists", {
  expect_true(nzchar(app_data_dir()))
  expect_true(dir.exists(app_data_dir()) ||
                dir.exists("/srv/nyctaxi/data") ||
                dir.exists("/data"))
})

test_that("ordinal renders the percentile the way 4.6 spells it", {
  expect_equal(ordinal(1), "1st")
  expect_equal(ordinal(2), "2nd")
  expect_equal(ordinal(3), "3rd")
  expect_equal(ordinal(4), "4th")
  expect_equal(ordinal(11), "11th")
  expect_equal(ordinal(12), "12th")
  expect_equal(ordinal(13), "13th")
  expect_equal(ordinal(21), "21st")
  expect_equal(ordinal(73), "73rd")
  expect_equal(ordinal(100), "100th")
  expect_equal(ordinal(62.5), "62nd")
  expect_equal(ordinal(NA), "")
})


# ---- share URLs and the structured click log (7.3, 7.4) ---------------------

test_that("share_base_url never keeps a trailing slash", {
  old <- Sys.getenv("SHARE_BASE_URL", unset = NA)
  on.exit(if (is.na(old)) Sys.unsetenv("SHARE_BASE_URL")
          else Sys.setenv(SHARE_BASE_URL = old))
  Sys.setenv(SHARE_BASE_URL = "http://localhost:8020/")
  expect_equal(share_base_url(), "http://localhost:8020")
  Sys.setenv(SHARE_BASE_URL = "")
  expect_equal(share_base_url(), "https://nyctaxiapp.angelfeliz.com")
})

test_that("share_url builds the card link and refuses an empty token", {
  old <- Sys.getenv("SHARE_BASE_URL", unset = NA)
  on.exit(if (is.na(old)) Sys.unsetenv("SHARE_BASE_URL")
          else Sys.setenv(SHARE_BASE_URL = old))
  Sys.setenv(SHARE_BASE_URL = "https://example.org")
  expect_equal(share_url("aZ3kQ9mLp1Rt"), "https://example.org/share/aZ3kQ9mLp1Rt")
  expect_equal(share_url(""), "")
  expect_equal(share_url(NULL), "")
  expect_equal(share_url(NA_character_), "")
})

test_that("log_event writes one JSON object per line to stderr", {
  out <- capture.output(log_event("share_click", channel = "x"),
                        type = "message")
  expect_length(out, 1)
  parsed <- jsonlite::fromJSON(out)
  expect_equal(parsed$event, "share_click")
  expect_equal(parsed$channel, "x")
  expect_true(nzchar(parsed$ts))
})
