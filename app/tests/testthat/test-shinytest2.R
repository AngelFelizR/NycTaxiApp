# Phase-4 flow test: Setup -> validate -> Start The Day -> resume-code modal ->
# Trips, plus the X-Client-IP forwarding the phase deliverable asks for.
#
# The real app runs against dev/mock_api.R (canned answers: no models, no
# database, no rate limit) in a headless Chromium driven by shinytest2.

skip_if_not_installed("shinytest2")
skip_if_not_installed("callr")
skip_if_not_installed("chromote")
skip_if_not_installed("withr")

# find_chrome() returns NULL (not an error) when nothing is on the PATH, and
# nzchar(NULL) is logical(0), which skip_if() would silently drop -- so the
# NULL has to be handled explicitly or shinytest2 fails with a vaguer message.
chrome <- tryCatch(chromote::find_chrome(), error = function(e) NULL)
skip_if(
  is.null(chrome) || !nzchar(chrome),
  paste("no Chrome/Chromium on the PATH: run this suite with",
        "`nix-shell app/default.dev.nix` (nix/test-tools.nix provides it)")
)

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

# The active navbar tab, as text -- app.R moves to Results when /finish lands.
active_tab <- function() {
  app$get_js(paste0("(function(){ var a = document.querySelector(",
                    "'.nav-link.active'); return a ? a.textContent.trim() : ''; })()"))
}
on_results <- function() identical(active_tab(), "Results")

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

# --- 3. the advanced seed option (3.3) --------------------------------------

test_that("the advanced seed option accepts a custom seed", {
  # set_inputs() reaches the reactive for the always-visible fields but not for
  # one revealed by a conditionalPanel, so drive both the toggle and the value
  # the way the browser would.
  app$run_js("document.querySelector('#setup-advanced').click()")
  app$wait_for_js(paste0(
    "(function(){ var e = document.querySelector('#setup-seed');",
    "return !!e && e.offsetParent !== null; })()"), timeout = 15000)
  expect_true(visible("#setup-seed"))

  app$run_js("Shiny.setInputValue('setup-seed', '4242', {priority: 'event'})")
  # The seed reaches the API, not the DOM: the unofficial badge in Results is
  # the only place it shows up (3.3).
})

# --- 4. Start The Day opens the resume-code modal --------------------------

test_that("Start The Day shows the one-time resume code in a modal", {
  app$click(selector = "#setup-start_day")
  has_text(".modal code", "[A-Za-z0-9_-]{8,}", timeout = 30000)
  expect_true(js_truthy("!!document.querySelector('#confirm-continue')"))
  # updateQueryString() only rewrites the address bar, so ask the page rather
  # than the driver, which still remembers the URL it navigated to.
  expect_match(app$get_js("window.location.search"), "\\?exp=")
})

# --- 5. Continue lands on Trips and the day becomes playable ----------------

test_that("the day reaches Trips with its sidebar, clock bar and hints", {
  app$click(selector = "#confirm-continue")

  # app.R polls /state every second while status is "setup"; the mock flips to
  # in_progress on the second poll and only then offers a trip.
  has_text("#trips-current_time", "[0-9]{4}-[0-9]{2}-[0-9]{2}", timeout = 45000)
  has_text("#trips-card-trip_miles", "[0-9.]+", timeout = 45000)

  # 6.5: the offer, the sidebar KPIs, the pending-time bar and the shortcut
  # footer are all part of the screen, and the bar has been sized by shinyjs.
  expect_true(visible("#trips-card-accept"))
  expect_true(js_truthy("!!document.querySelector('.trips-sidebar')"))
  expect_true(js_truthy("!!document.querySelector('.pending-bar')"))
  expect_true(js_truthy(paste0(
    "(function(){var e=document.querySelector('#trips-pending_fill');",
    "return !!e && /%$/.test(e.style.width || '');})()")))
  expect_true(visible(".kbd-footer"))
  expect_true(js_truthy("!!document.querySelector('#trips-resume')"))

  # 3.11: no running comparison against the model on this screen -- the
  # agreement score is reserved for Results.
  sidebar <- app$get_js("document.querySelector('.trips-sidebar').textContent")
  expect_match(sidebar, "Earnings so far")
  expect_match(sidebar, "Decisions")
  expect_false(grepl("Following Policy", sidebar, fixed = TRUE))
})

# --- 6. accepting a trip advances the day ----------------------------------

test_that("accepting a trip moves the simulated clock", {
  before <- app$get_text("#trips-current_time")
  app$click(selector = "#trips-card-accept")
  app$wait_for_js(sprintf(
    "(function(){ var e = document.querySelector('#trips-current_time'); return !!e && e.textContent !== %s; })()",
    jsonlite::toJSON(before, auto_unbox = TRUE)
  ), timeout = 30000)
  expect_true(nzchar(app$get_text("#trips-current_time")))
})

# --- 7. the keyboard shortcuts preselect and confirm ------------------------

key <- function(k) {
  app$run_js(sprintf(
    "document.dispatchEvent(new KeyboardEvent('keydown', {key: %s}));",
    jsonlite::toJSON(k, auto_unbox = TRUE)
  ))
}

test_that("the arrow keys preselect and Enter sends the decision", {
  before <- app$get_text("#trips-current_time")

  key("ArrowRight")
  expect_true(js_truthy("!!document.querySelector('#trips-card-accept.preselected')"))
  expect_false(js_truthy("!!document.querySelector('#trips-card-reject.preselected')"))

  # Pressing again must clear it, never send anything by itself.
  key("ArrowRight")
  expect_false(js_truthy("!!document.querySelector('#trips-card-accept.preselected')"))
  expect_equal(app$get_text("#trips-current_time"), before)

  key("ArrowLeft")
  expect_true(js_truthy("!!document.querySelector('#trips-card-reject.preselected')"))

  # Enter confirms through exactly the same button a click would.
  key("Enter")
  expect_false(js_truthy("!!document.querySelector('.trip-actions .preselected')"))
  app$wait_for_js(sprintf(
    "(function(){ var e = document.querySelector('#trips-current_time'); return !!e && e.textContent !== %s; })()",
    jsonlite::toJSON(before, auto_unbox = TRUE)
  ), timeout = 30000)
})

test_that("the ? key opens the shortcuts dialog and Esc closes it", {
  key("?")
  has_text(".modal", "Keyboard shortcuts", timeout = 15000)
  expect_true(js_truthy("!!document.querySelector('.modal')"))

  key("Escape")
  app$wait_for_js("!document.querySelector('.modal')", timeout = 15000)
  expect_false(js_truthy("!!document.querySelector('.modal')"))
})

# --- 8. playing out the shift ends the day and opens Results ----------------

test_that("the shift ends on /finish and lands on Results", {
  # The mock advances 45 simulated minutes per decision, so the 8h shift
  # closes after 11 offers and then answers 409 to any further one. Nothing
  # else flips the day to finished: the UI has to call POST /finish, which is
  # what computes outcome and the percentile on the server (4.6).
  for (i in seq_len(40)) {
    if (on_results()) break
    if (!visible("#trips-card-accept")) { Sys.sleep(0.5); next }
    before <- app$get_text("#trips-current_time")
    app$click(selector = "#trips-card-accept")
    # Either the clock moves, or the day ended and app.R switched panels.
    try(app$wait_for_js(sprintf(
      paste0("(function(){",
             " var e = document.querySelector('#trips-current_time');",
             " var a = document.querySelector('.nav-link.active');",
             " return (!!e && e.textContent !== %s) ||",
             "        (!!a && a.textContent.trim() === 'Results');",
             " })()"),
      jsonlite::toJSON(before, auto_unbox = TRUE)
    ), timeout = 6000), silent = TRUE)
  }
  expect_true(on_results())
})

# --- 9. Results: six KPIs, the percentile sentence and the seed badge -------

test_that("Results shows the KPIs, the percentile and the custom-seed badge", {
  expect_true(on_results())

  # The seed was set to 4242 during Setup, so the day is not official (3.3).
  expect_true(visible(".custom-seed"))

  # 4.6: the percentile is a sentence under the curves, never a seventh KPI.
  has_text("#results-percentile", "62nd percentile")
  has_text("#results-percentile_note", "single sample")

  # The six KPIs (6.5) all carry a value.
  for (kpi in c("earnings", "hourly", "vs_policy", "accepted", "rejected",
                "following")) {
    v <- app$get_js(sprintf(
      "document.querySelector('#results-%s') ? document.querySelector('#results-%s').textContent.trim() : ''",
      kpi, kpi))
    expect_true(nzchar(v), label = paste("KPI", kpi))
  }
  # The comparison is a number with an arrow, not just a colour (3.11).
  expect_match(app$get_text("#results-vs_policy"), "\u25b2|\u25bc")

  # Technical details stay reachable (6.5: never a KPI).
  expect_true(js_truthy("!!document.querySelector('#results-exp_id')"))
  expect_match(app$get_text("#results-exp_id"), "[0-9a-f-]{8,}")

  # The three cumulative curves rendered. The htmlwidget paints
  # asynchronously, so wait for it rather than sampling once.
  app$wait_for_js(paste0(
    "(function(){ var e = document.querySelector('#results-plot_history');",
    "return !!e && e.children.length > 0; })()"), timeout = 25000)
  expect_true(js_truthy(paste0(
    "(function(){ var e = document.querySelector('#results-plot_history');",
    "return !!e && e.children.length > 0; })()")))
  expect_true(visible("#results-feedback"))
})

# --- 10. the feedback modal (6.5) ------------------------------------------

test_that("the feedback modal saves a rating", {
  app$click(selector = "#results-feedback")
  has_text(".modal", "How was your day", timeout = 15000)

  # Submitting without a rating must not close the dialog.
  app$click(selector = "#results-feedback-send")
  Sys.sleep(1)
  expect_true(js_truthy("!!document.querySelector('.modal')"))

  # A real click on the radio, inside the modal, is what a player does.
  app$run_js(paste0(
    "var r = document.querySelector('input[name=\"results-feedback-rating\"]",
    "[value=\"4\"]'); if (r) r.click();"))
  app$click(selector = "#results-feedback-send")
  app$wait_for_js("!document.querySelector('.modal')", timeout = 20000)
  expect_false(js_truthy("!!document.querySelector('.modal')"))
})

# --- 11. the app forwarded the client IP ------------------------------------

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
