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

api_async <- function(fn, ctx, ...) {
  ensure_daemons()
  mirai::mirai(
    do.call(fn, c(list(ctx = ctx), args)),
    fn = fn, ctx = ctx, args = list(...)
  )
}

# Read an ExtendedTask result inside an observer/reactive:
#  - still pending / never invoked -> re-raise Shiny's silent error (waits quietly)
#  - failed (HTTP error, timeout, daemon error) -> notify the user, return NULL
task_result <- function(task) {
  tryCatch(task$result(), error = function(e) {
    if (inherits(e, "shiny.silent.error")) stop(e)
    showNotification(paste(err_api_prefix, conditionMessage(e)),
                     type = "error", duration = 8)
    NULL
  })
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
