# Decide as Taxi Driver For A Day -- thin Shiny client for a plumber2 API.
# UI + non-blocking API calls (httr2 running in mirai daemons). No domain logic.
#
# The package, loaded exactly once (ADR-0007). R/ holds
# _disable_autoload.R, which stops Shiny's loadSupport() from sourcing this
# directory into the environment this file is evaluated in: two copies of
# every object -- including constants_state, which must be exactly one -- is
# how a module ends up disagreeing with app.R about state. The image installs
# the package (app/Dockerfile: R CMD INSTALL) so production takes the
# library() branch; a development shell has no installed copy and loads the
# source instead, with pkgload from nix/r-dev.nix. cwd is the app directory
# in every entry point (runApp, the Docker CMD and shinytest2's AppDriver).
if (requireNamespace("taxiapp", quietly = TRUE)) {
  suppressPackageStartupMessages(library(taxiapp))
} else {
  pkgload::load_all(".", export_all = TRUE, helpers = FALSE,
                    attach_testthat = FALSE, quiet = TRUE)
}
library(shiny)
library(bslib)
library(leaflet)
library(httr2)
library(mirai)
# ggplot2 is deliberately absent: it is attached on first chart (ensure_ggplot2)
# because it costs ~0.9 s of the 3 s startup budget.

# Dev convenience: the single .env at the repo root. In production Docker and
# ShinyProxy inject the variables and this file does not exist.
load_env_file(file.path("..", ".env"))
load_env_file(".env")

# The mirai workers are started lazily on the first API call (ensure_daemons,
# R/utils.R); this only tears them down when the app stops.
onStop(function() if (isTRUE(getOption("taxi.daemons"))) mirai::daemons(0))

ui <- page_navbar(
  id = "nav_principal",
  theme = theme_taxi(),
  title = app_title,
  fillable = FALSE,
  header = tagList(
    shinyjs::useShinyjs(),   # mod_confirm_modal copies the resume code with runjs()
    # Keyboard shortcuts for Trips (6.5). Loaded once here so mod_trips only
    # has to send its ids, and www/js is served as a normal Shiny resource.
    tags$script(src = "js/shortcuts.js"),
    mod_header_ui("header")
  ),
  nav_panel(nav_setup,   value = "setup",   mod_setup_ui("setup")),
  nav_panel(nav_trips,   value = "trips",   mod_trips_ui("trips")),
  nav_panel(nav_results, value = "results", mod_results_ui("results")),
  nav_spacer(),
  nav_item(input_dark_mode(id = "modo"))
,
  # 9.1: the privacy notice has to be reachable from Setup, the footer and the
  # email form. page_navbar's `footer` renders under every panel, so this one
  # link covers the whole product.
  footer = div(class = "text-center text-muted small py-2",
    tags$a(label_privacy, href = "privacy.html", target = "_blank",
           rel = "noopener"))
)

server <- function(input, output, session) {
  estado <- init_estado(session)
  mod_header_server("header", estado)

  # input_dark_mode() is a top-level input, so a module would never see it
  # under its own namespace: publish one derived reactive instead.
  dark <- reactive(identical(input$modo, "dark"))

  restart <- reactiveVal(0)
  setup   <- mod_setup_server("setup", estado, reset = restart)
  # on_continue runs inside mod_confirm_modal's observer, so getDefaultReactiveDomain()
  # there is the *module* session: pass the root session explicitly or
  # nav_select() would target "confirm-nav_principal".
  confirm <- mod_confirm_modal_server(
    "confirm", estado,
    on_continue = function() nav_select("nav_principal", "trips", session = session)
  )
  trips   <- mod_trips_server("trips", estado, reset = restart, dark = dark)
  results <- mod_results_server("results", estado, reset = restart)

  # Start The Day -> one-time resume code in a modal; Trips only after the
  # player has seen it (6.5).
  observeEvent(setup$day(), {
    req(setup$day())
    confirm$open()
  }, ignoreInit = TRUE)

  # Starting over drops the whole session state (6.1.5: nothing survives in
  # globals) and clears the ?exp= bookmark so the URL cannot resurrect it.
  observeEvent(restart(), {
    req(restart() > 0)
    estado$experiment_id  <- NULL
    estado$resume_code    <- NULL
    estado$share_token    <- NULL
    estado$state          <- NULL
    estado$status         <- NULL
    estado$progress       <- 0L
    estado$result         <- NULL
    estado$experiment     <- NULL
    estado$email          <- NULL
    session$updateQueryString("?", mode = "replace")
    nav_select("nav_principal", "setup", session = session)
  }, ignoreInit = TRUE)

  # The day ends on POST /finish (mod_trips fires it when the clock runs out);
  # that is the moment Results has something to show.
  observeEvent(estado$status, {
    if (identical(estado$status, "finished")) {
      nav_select("nav_principal", "results", session = session)
    }
  })

  # While the policy and baseline trajectories are computed in the background,
  # /state is the only signal: model_progress climbs to 99 and the status
  # flips to in_progress (section 4.6).
  poll_task <- ExtendedTask$new(function(ctx, id) {
    api_async("api_get_state", ctx, id)
  })
  observe({
    req(estado$experiment_id, identical(estado$status, "setup"))
    invalidateLater(1000, session)
    if (poll_task$status() != "running") {
      poll_task$invoke(estado_ctx(estado), estado$experiment_id)
    }
  })
  observe({
    res <- task_result(poll_task)
    if (!is.null(res)) estado_set_state(estado, res)
  })
}

shinyApp(ui, server)
