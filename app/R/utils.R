# UI-only helpers + the bridge between Shiny and mirai --------------------------
intro_text <- function() {
  div(
    p("This app will help you to validate what is the best strategy to work as a ",
      "taxi driver in NYC and increase the earning without working any extra hour."),
    p("If you want to see the whole process before getting in the app please check ",
      tags$a("this web site", href = "#"), " and the corresponding ",
      tags$a("repo", href = "#"), ".")
  )
}

basemap <- function() {
  leaflet() |>
    addProviderTiles("CartoDB.Positron") |>
    setView(-73.85, 40.72, 10)
}

line_plot <- function(df, col) {
  ggplot(df, aes(.data$step, .data[[col]])) +
    geom_line(colour = "#2c7a7b") + geom_point(colour = "#2c7a7b") +
    labs(x = "Trips", y = "Earnings ($)") +
    theme_minimal()
}

has_hint <- function(x) is.character(x) && length(x) == 1 && nzchar(x)
zone_or_null <- function(x) if (is.null(x) || identical(x, "-")) NULL else x

# Run an API function (by name, defined in R/api_client.R) in a mirai daemon.
# Returns a mirai, which ExtendedTask turns into a promise.
api_async <- function(fn, ...) {
  mirai::mirai(
    {
      Sys.setenv(TAXI_API_URL = url)   # daemons may have been started before it was set
      do.call(fn, args)
    },
    fn = fn, args = list(...), url = api_base_url()
  )
}

# Read an ExtendedTask result inside an observer/reactive:
#  - still pending / never invoked -> re-raise Shiny's silent error (waits quietly)
#  - failed (HTTP error, timeout, daemon error) -> notify the user, return NULL
task_result <- function(task) {
  tryCatch(task$result(), error = function(e) {
    if (inherits(e, "shiny.silent.error")) stop(e)
    showNotification(paste("API error:", conditionMessage(e)),
                     type = "error", duration = 8)
    NULL
  })
}
