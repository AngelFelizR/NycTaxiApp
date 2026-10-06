# Phase-4 flow test: Setup -> validate -> Start The Day -> resume-code modal ->
# Trips, plus the X-Client-IP forwarding the phase deliverable asks for.
#
# The real app runs against dev/mock_api.R (canned answers: no models, no
# database, no rate limit) in a headless Chromium driven by shinytest2.

skip_if_not_installed("shinytest2")
skip_if_not_installed("callr")
skip_if_not_installed("chromote")
skip_if_not_installed("withr")

chrome <- tryCatch(chromote::find_chrome(), error = function(e) "")
skip_if(!nzchar(chrome), "no Chrome/Chromium on the PATH")

# Random port: probing with socketConnection(server = TRUE) blocks, and this
# file runs once per invocation, so a collision would be a fluke anyway.
mock_port <- sample(8300:8999, 1)
mock_key  <- "shinytest2-internal-key"
mock_url  <- sprintf("http://127.0.0.1:%d", mock_port)
mock_out  <- tempfile(fileext = ".out")
mock_err  <- tempfile(fileext = ".err")

# supervise = TRUE: callr kills the mock when this R process exits, even if an
# assertion below throws before the explicit cleanup at the end of the file.
mock_proc <- callr::r_bg(
  function(app_dir, port, key) {
    setwd(app_dir)
    Sys.setenv(API_INTERNAL_KEY = key)
    source("dev/mock_api.R")
    plumber2::api_run(mock_api(port = port), block = TRUE, silent = TRUE)
  },
  args = list(app_dir = app_dir, port = mock_port, key = mock_key),
  stdout = mock_out, stderr = mock_err, supervise = TRUE
)

mock_ready <- FALSE
for (i in seq_len(100)) {
  Sys.sleep(0.2)
  if (!mock_proc$is_alive()) break
  ok <- tryCatch({
    httr2::request(paste0(mock_url, "/health")) |>
      httr2::req_headers(`X-Internal-Key` = mock_key) |>
      httr2::req_timeout(1) |>
      httr2::req_perform()
    TRUE
  }, error = function(e) FALSE)
  if (ok) { mock_ready <- TRUE; break }
}
if (!mock_ready) {
  writeLines(c("--- mock stdout ---", readLines(mock_out, warn = FALSE),
               "--- mock stderr ---", readLines(mock_err, warn = FALSE)))
}
skip_if_not(mock_ready, "the mock API did not come up")

withr::local_envvar(c(
  TAXI_API_URL = mock_url,
  API_INTERNAL_KEY = mock_key,
  ENV = "development",
  # AppDriver refuses to start when testthat thinks we are on CRAN.
  NOT_CRAN = "true"
))

app <- shinytest2::AppDriver$new(
  app_dir = app_dir, load_timeout = 30000,
  height = 900, width = 1200, wait = TRUE
)

# Nginx/ShinyProxy would set X-Client-IP on the request that opens the Shiny
# session. The header has to be in place before that request is made, so
# inject it at the browser level and reload: the reload creates a fresh Shiny
# session whose upgrade request carries it.
cs <- app$get_chromote_session()
invisible(cs$send_command(list(method = "Network.enable")))
invisible(cs$send_command(list(
  method = "Network.setExtraHTTPHeaders",
  params = list(headers = list(`X-Client-IP` = "203.0.113.9"))
)))
app$run_js("window.location.reload()")
app$wait_for_js("!!document.querySelector('#setup-validate')", timeout = 30000)

# --- helpers ----------------------------------------------------------------

js_truthy <- function(script) app$get_js(sprintf("!!(%s)", script))

has_text <- function(selector, pattern, timeout = 20000) {
  app$wait_for_js(sprintf(
    "(function(){ var e = document.querySelector(%s); return !!e && e.textContent.search(%s) >= 0; })()",
    jsonlite::toJSON(selector, auto_unbox = TRUE),
    jsonlite::toJSON(pattern, auto_unbox = TRUE)
  ), timeout = timeout)
}

# conditionalPanel() only toggles display, so offsetParent tells us whether a
# panel is actually on screen.
visible <- function(selector) {
  js_truthy(sprintf(
    "(function(){ var e = document.querySelector(%s); return !!e && e.offsetParent !== null; })()",
    jsonlite::toJSON(selector, auto_unbox = TRUE)
  ))
}

# --- 1. the form is up and starts unvalidated -------------------------------

test_that("the setup form is ready and starts unvalidated", {
  app$wait_for_js("!!document.querySelector('#setup-company')", timeout = 20000)
  expect_true(js_truthy("!!document.querySelector('#setup-start_dt')"))
  expect_true(js_truthy("!!document.querySelector('#setup-validate')"))
  expect_false(visible("#setup-start_day"))
})

# --- 2. validating shows the hints -----------------------------------------

test_that("validating a non-optimal start shows both hints", {
  app$set_inputs(
    `setup-company` = "Lyft",
    `setup-start_dt` = "2024-05-12 00:00",
    `setup-start_zone` = "61",
    timeout_ = 15000
  )
  app$click(selector = "#setup-validate")

  # The mock answers better_company = Uber, better_datetime = 20:00.
  has_text("#setup-company_hint", "Use Uber for better results")
  has_text("#setup-datetime_hint", "2024-05-12T20:00:00Z")
  expect_true(visible("#setup-start_day"))
})

# --- 3. Start The Day opens the resume-code modal --------------------------

test_that("Start The Day shows the one-time resume code in a modal", {
  app$click(selector = "#setup-start_day")
  has_text(".modal code", "[A-Za-z0-9_-]{8,}", timeout = 30000)
  expect_true(js_truthy("!!document.querySelector('#confirm-continue')"))
  # updateQueryString() only rewrites the address bar, so ask the page rather
  # than the driver, which still remembers the URL it navigated to.
  expect_match(app$get_js("window.location.search"), "\\?exp=")
})

# --- 4. Continue lands on Trips and the day becomes playable ----------------

test_that("the day reaches Trips and becomes playable", {
  app$click(selector = "#confirm-continue")

  # app.R polls /state every second while status is "setup"; the mock flips to
  # in_progress on the second poll and only then offers a trip.
  has_text("#trips-current_time", "[0-9]{4}-[0-9]{2}-[0-9]{2}", timeout = 45000)
  has_text("#trips-trip_miles", "[0-9.]+", timeout = 45000)
  expect_true(visible("#trips-accept"))
})

# --- 5. accepting a trip advances the day ----------------------------------

test_that("accepting a trip moves the simulated clock", {
  before <- app$get_text("#trips-current_time")
  app$click(selector = "#trips-accept")
  app$wait_for_js(sprintf(
    "(function(){ var e = document.querySelector('#trips-current_time'); return !!e && e.textContent !== %s; })()",
    jsonlite::toJSON(before, auto_unbox = TRUE)
  ), timeout = 30000)
  expect_true(nzchar(app$get_text("#trips-current_time")))
})

# --- 6. the app forwarded the client IP ------------------------------------

test_that("the API received the X-Client-IP the app saw", {
  seen <- httr2::request(paste0(mock_url, "/__last")) |>
    httr2::req_headers(`X-Internal-Key` = mock_key) |>
    httr2::req_timeout(5) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  expect_equal(seen$ip, "203.0.113.9")
  expect_equal(seen$key, mock_key)
})

# --- cleanup (runs whatever the assertions above did) ----------------------

app$stop()
mock_proc$kill()
