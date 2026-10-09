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
  # Nothing to fall back *to* on a machine with no volume mounted; asserting
  # that one of the hard-coded paths exists was a claim about the machine,
  # not about the code, and it failed on every CI runner. What the code
  # promises is that the first candidate that exists wins -- checked here when
  # there is one, and checked as a list in the test below.
  cands <- app_data_candidates()
  cands <- cands[nzchar(cands)]
  existing <- cands[dir.exists(cands)]
  skip_if_not(length(existing) > 0L, "no data volume is mounted here")
  expect_identical(app_data_dir(), existing[[1L]])
})

test_that("app_data_dir knows every place the data volume is mounted", {
  # §8.3 mounts it at /app/data and §6.1.3 names /srv/nyctaxi/data; the dev
  # compose uses /data. All three have to be candidates or the map comes up
  # empty in that layout and nothing says why.
  cands <- app_data_candidates()
  expect_true("/app/data" %in% cands, label = "the §8.3 mount target")
  expect_true("/data" %in% cands, label = "the dev compose mount")
  expect_true("/srv/nyctaxi/data" %in% cands, label = "the §6.1.3 production path")
  # DATA_DIR wins when the environment provides one.
  expect_identical(app_data_candidates()[1], Sys.getenv("DATA_DIR", ""))
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

# task_result is the only place that translates an ExtendedTask's three
# answers for the seven callers (utils.R). A failure has to come back as NULL
# -- the callers all do `if (!is.null(res))` -- and a task that is still
# running has to re-raise its silent error instead of being mistaken for a
# failure, because mod_trip_card arms its /state resync on the difference.
fake_task <- function(result) list(result = function() result)

test_that("task_result unwraps the value of a settled task", {
  expect_equal(task_result(fake_task(list(value = list(x = 1)))),
               list(x = 1))
})

test_that("task_result reports an API failure as NULL, not a value", {
  # The failure branch notifies, and showNotification needs a reactive domain
  # ("attempt to apply non-function" without one). taxiapp declares no imports
  # (ADR-0007: exportPattern only), so showNotification is found on the search
  # path and cannot be mocked in the package's namespace -- the smallest real
  # thing is a duck of a session that records what it was told.
  notified <- NULL
  session <- list(sendNotification = function(type, message, ...) {
    notified <<- list(type = type, message = message)
  })
  out <- shiny::withReactiveDomain(session, {
    task_result(fake_task(list(failure = "Models are not loaded.")))
  })
  expect_null(out)
  # showNotification hands the session a nested payload, not a plain string;
  # flatten it before looking for the API's own message inside.
  expect_false(is.null(notified))
  expect_match(paste(unlist(notified), collapse = " "),
               "Models are not loaded", fixed = TRUE)
})

test_that("task_result re-raises the silent error of a task still running", {
  # Mirrors what a pending ExtendedTask throws: shiny.silent.error inherits
  # from "error" (only then does task_result's tryCatch(error=) see it), with
  # the message Shiny strips on the way across. Getting the classes wrong here
  # does not fail the assertion -- the condition escapes and halts the run.
  running <- structure(list(message = "", call = NULL),
                       class = c("shiny.silent.error", "error", "condition"))
  expect_error(task_result(fake_task(stop(running))),
               class = "shiny.silent.error")
})

test_that("finish_can_invoke starts once, retries bounded, never while a resync runs", {
  # First attempt when the clock runs out. ExtendedTask calls that state
  # "initial" -- there is no "idle" -- and blocking it leaves every day on a
  # blank Trips screen, so the test pins the real word.
  expect_true(finish_can_invoke("initial", 0L, FALSE))
  # A settled attempt may be retried while attempts remain...
  expect_true(finish_can_invoke("success", 1L, FALSE))
  expect_true(finish_can_invoke("error", 2L, FALSE))
  # ...but not past the cap (the 503-forever case), and never before the
  # resync has answered -- a /finish that timed out is already stored and a
  # re-post only finds 409.
  expect_false(finish_can_invoke("success", 3L, FALSE))
  expect_false(finish_can_invoke("success", 1L, TRUE))
  # One in-flight finish is plenty.
  expect_false(finish_can_invoke("running", 0L, FALSE))
})

test_that("load_env_file treats a blank value as unset, not as empty", {
  # .env.example ships optional knobs as `VAR=`; setting them to "" would
  # defeat every Sys.getenv(VAR, "default") in the client (R answers "" for
  # a set-but-empty variable). Same rule as the api/share loaders.
  path <- tempfile(fileext = ".env")
  writeLines(c("BLANK_FROM_ENV=", "FILLED_FROM_ENV=hello"), path)
  on.exit({
    unlink(path)
    Sys.unsetenv("BLANK_FROM_ENV")
    Sys.unsetenv("FILLED_FROM_ENV")
  }, add = TRUE)
  Sys.unsetenv("BLANK_FROM_ENV")
  Sys.unsetenv("FILLED_FROM_ENV")
  expect_true(load_env_file(path))
  expect_identical(Sys.getenv("BLANK_FROM_ENV", unset = NA_character_),
                   NA_character_, label = "blank line left the variable unset")
  expect_identical(Sys.getenv("FILLED_FROM_ENV"), "hello")
})
