# UI-only helpers + the bridge between Shiny and mirai --------------------------

# ggplot2 costs ~0.9 s to attach and no chart exists before the first paint,
# so it is loaded on first use instead of at startup (phase-4 criterion: the
# app must be listening in under 3 s).
ensure_ggplot2 <- function() {
  if (!"package:ggplot2" %in% search()) library(ggplot2)
  invisible(TRUE)
}

intro_text <- function() {
  div(
    p(setup_intro_1),
    p(
      setup_intro_2_a,
      tags$a(setup_intro_2_b, href = "#"),
      setup_intro_2_c,
      tags$a(setup_intro_2_d, href = "#"),
      setup_intro_2_e
    )
  )
}

# CartoDB.Positron stays for the light theme (6.5 switches it with
# leafletProxy when the dark mode is on -- phase 5).
basemap <- function() {
  leaflet() |>
    addProviderTiles("CartoDB.Positron") |>
    setView(-73.85, 40.72, 10)
}

has_hint <- function(x) is.character(x) && length(x) == 1 && nzchar(x)
zone_or_null <- function(x) if (is.null(x) || identical(x, "-")) NULL else x

# Run an API function (by name, defined in R/api_client.R) inside a mirai
# daemon, with the request context (URL, key, IP, resume code) captured in
# the Shiny process. Returns a mirai, which ExtendedTask turns into a promise.
#
# The workers are started on the first call rather than at startup: spawning
# four R processes costs ~0.6 s and nothing talks to the API before the first
# visitor clicks, which is what keeps the app listening in under 3 s.
ensure_daemons <- function(n = 4) {
  if (isTRUE(getOption("taxi.daemons"))) return(invisible(FALSE))
  options(taxi.daemons = TRUE)
  api_file <- normalizePath(file.path("R", "api_client.R"))
  mirai::daemons(n)
  mirai::everywhere({
    library(httr2)
    source(api_file)
  }, api_file = api_file)
  invisible(TRUE)
}

# A rejected promise reaches task_result() as `shiny.silent.error` with an
# EMPTY message -- Shiny discards the text on the way across -- so a failing
# call used to vanish: no notification, no log, nothing. The visitor clicked
# and nothing happened. Caught by section 10's status test: it was
# test-shinytest2.R's 429 scenario, it is rate-limit.cy.js now, and it reads
# the API's own message off the notification.
#
# So the call never rejects: it resolves to `list(failure = <message>)` and
# the reader decides. Daemons that will not start are handled the same way,
# through promise_resolve, because that path cannot build a mirai either.
api_async <- function(fn, ctx, ...) {
  tryCatch({
    ensure_daemons()
    mirai::mirai(
      tryCatch(list(value = do.call(fn, c(list(ctx = ctx), args))),
               error = function(e) list(failure = conditionMessage(e))),
      fn = fn, ctx = ctx, args = list(...)
    )
  }, error = function(e) {
    promises::promise_resolve(list(
      failure = paste("could not start the API workers:", conditionMessage(e))
    ))
  })
}

# Read an ExtendedTask result inside an observer/reactive:
#  - still pending / running -> re-raise the silent error (waits quietly)
#  - failed -> notify the user with the API's own message, return NULL
#  - ok -> the value the api_* function returned, unwrapped
# Callers all do `res <- task_result(t); if (!is.null(res)) ...`, so NULL on
# failure keeps every one of them correct without touching them.
# May the UI start (or start again) POST /finish? Three rules, extracted
# because they are a policy, not plumbing -- and because getting them wrong is
# how a day ends on a blank Trips screen instead of Results:
#
#   - "idle": the clock just ran out, always allowed.
#   - a settled task ("success"/"error") may be retried, but only while the
#     attempts are under max_attempts: a missing ReferenceDistribution.qs2
#     answers 503 forever, and re-raising it once per flush would notify
#     forever (the guard the original comment guarded).
#   - never while a resync is in flight: a /finish that timed out after 45 s
#     is STILL STORED server side, and re-posting gets 409 "already finished"
#     -- an answer with no result in it. The GET /state that the resync runs
#     does carry `result` for a finished day, so waiting for it is what turns
#     the timeout into a recovery instead of a dead end.
#
# "running" is never allowed: one in-flight finish is plenty.
finish_can_invoke <- function(task_status, attempts, recovering,
                              max_attempts = 3L) {
  # ExtendedTask's own vocabulary (shiny::ExtendedTask$private$rv_status):
  # "initial" before the first invoke -- there is no "idle" -- then
  # "running", "success", "error". A wrong first word here silently blocks
  # /finish forever: every session ends on an empty Trips screen.
  if (task_status %in% c("initial", "idle")) return(TRUE)
  if (!task_status %in% c("success", "error")) return(FALSE)
  attempts < max_attempts && !isTRUE(recovering)
}

task_result <- function(task) {
  out <- tryCatch(task$result(), error = function(e) stop(e))
  if (!is.list(out)) return(out)
  if (!is.null(out$failure)) {
    showNotification(paste(err_api_prefix, out$failure),
                     type = "error", duration = 8)
    return(NULL)
  }
  out$value
}

# POST /validate-trip-start answer -> the three hints the form shows. The API
# only says whether the start is optimal and what would be better, so the copy
# (and the comparison against what the user typed) lives here, next to the
# other UI helpers.
validation_hints <- function(res, company, datetime) {
  empty <- list(company_hint = "", datetime_hint = "", message = "")
  if (is.null(res)) return(empty)
  if (isTRUE(res$is_optimal)) {
    return(list(company_hint = "", datetime_hint = "", message = msg_perfect))
  }
  better_company <- res$better_company %||% ""
  better_datetime <- res$better_datetime %||% ""
  same_datetime <- nzchar(better_datetime) &&
    identical(iso_8601(better_datetime), iso_8601(datetime))
  list(
    company_hint = if (nzchar(better_company) && !identical(better_company, company)) {
      sprintf(hint_company_fmt, better_company)
    } else {
      ""
    },
    datetime_hint = if (nzchar(better_datetime) && !same_datetime) {
      sprintf(hint_datetime_fmt, better_datetime)
    } else {
      ""
    },
    message = ""
  )
}

# Cumulative wage line for one trajectory (phase 5/6 charts). `history` is the
# DayState array: step, user, policy, baseline. The full data.frame is kept on
# the plot so callers can layer the other trajectories on top.
line_plot <- function(history, series) {
  ensure_ggplot2()
  stopifnot(is.data.frame(history), series %in% names(history))
  ggplot(history, aes(x = step, y = .data[[series]])) +
    geom_line(linewidth = 1) +
    geom_point(size = 1.5) +
    scale_x_continuous(breaks = function(l) pretty(l, n = 6)) +
    labs(x = "Decisions", y = "Cumulative pay ($)",
         title = tools::toTitleCase(series)) +
    theme_minimal()
}

# 4.6 renders the percentile as "the 21st percentile", so it needs the ordinal
# suffix; 11/12/13 are the irregulars and every -11/-12/-13 inherits them.
ordinal <- function(n) {
  n <- as.integer(round(as.numeric(n)[1]))
  if (is.na(n)) return("")
  sfx <- if (n %% 100 %in% c(11, 12, 13)) "th" else
    switch(as.character(n %% 10), "1" = "st", "2" = "nd", "3" = "rd", "th")
  paste0(n, sfx)
}

# --- adapters over the contract payloads, shared by trips and results ---------

# DayState.history: an array of {step, user, policy, baseline} that may arrive
# as a list of rows or already simplified into a data.frame.
history_df <- function(history) {
  if (is.data.frame(history)) {
    return(data.frame(
      step = as.numeric(history$step),
      user = as.numeric(history$user),
      policy = as.numeric(history$policy),
      baseline = as.numeric(history$baseline)
    ))
  }
  rows <- lapply(history, function(p) {
    data.frame(step = as.numeric(p$step), user = as.numeric(p$user),
               policy = as.numeric(p$policy), baseline = as.numeric(p$baseline))
  })
  if (length(rows) == 0) {
    return(data.frame(step = numeric(), user = numeric(),
                      policy = numeric(), baseline = numeric()))
  }
  do.call(rbind, rows)
}

# grid_original/grid_pu/grid_do: arrays of {trip_time_sec, driver_pay, prob}.
grid_df <- function(grid) {
  if (is.null(grid)) return(data.frame())
  if (is.data.frame(grid)) {
    return(data.frame(
      trip_time_sec = as.numeric(grid$trip_time_sec),
      driver_pay = as.numeric(grid$driver_pay),
      prob = as.numeric(grid$prob)
    ))
  }
  rows <- lapply(grid, function(p) {
    data.frame(trip_time_sec = as.numeric(p$trip_time_sec),
               driver_pay = as.numeric(p$driver_pay),
               prob = as.numeric(p$prob))
  })
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

# Centroids of the requested LocationIDs, in WGS84, in the given order (the
# caller colours pickup and drop-off differently, so the order matters).
zone_points <- function(z, ids) {
  ids <- ids[!is.na(ids) & !is.null(ids)]
  if (length(ids) == 0) return(NULL)
  sel <- z[as.character(z$LocationID) %in% as.character(ids), ]
  if (nrow(sel) == 0) return(NULL)
  pts <- suppressWarnings(sf::st_point_on_surface(sf::st_geometry(sel)))
  coords <- sf::st_coordinates(pts)
  sel$lng <- coords[, 1]
  sel$lat <- coords[, 2]
  ord <- match(as.character(ids), as.character(sel$LocationID))
  sel <- sel[stats::na.omit(ord), ]
  if (nrow(sel) == 0) NULL else sel
}

# Public origin the share URLs are built from (7.3): the buttons link at
# {base}/share/{token}, never at a relative path, because the page lives behind
# ShinyProxy and the card is served by a different service.
share_base_url <- function() {
  url <- Sys.getenv("SHARE_BASE_URL", "https://nyctaxiapp.angelfeliz.com")
  if (!nzchar(url)) url <- "https://nyctaxiapp.angelfeliz.com"
  sub("/+$", "", url)
}

share_url <- function(token) {
  tok <- trimws(as.character(token %||% "")[1])
  if (is.na(tok) || !nzchar(tok)) return("")
  paste0(share_base_url(), "/share/", tok)
}

# Structured log line on stderr (7.4): one JSON object per line, no logger
# dependency. `event` first so `grep share_click` still works in a raw log.
log_event <- function(event, ...) {
  payload <- c(list(event = event, ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ",
                                                tz = "UTC")),
               list(...))
  cat(jsonlite::toJSON(payload, auto_unbox = TRUE), "\n", sep = "", file = stderr())
  invisible(NULL)
}
