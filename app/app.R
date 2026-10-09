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
# in every entry point (runApp, the Docker CMD and the browser suite, which
# starts it through dev/e2e.sh).
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
  # 12: the document's language. Without it every screen reader reads the
  # English UI with the wrong voice, and pa11y reports it as an error on
  # <html> (H57.2 / html-has-lang). bslib only writes the attribute when it
  # is given, so it has to be said here.
  lang = "en",
  header = tagList(
    shinyjs::useShinyjs(),   # mod_confirm_modal copies the resume code with runjs()
    # The app's own stylesheet (www/styles.css): the reduced-motion rule of
    # section 12, the 44px tap targets and the keyboard-hint footer hidden on
    # touch (6.5), the warning text, the preselection outline. The <link> was
    # lost in the phase-5 migration from page_fluid to page_navbar and the
    # sheet has been served but never loaded ever since -- the mobile
    # checklist (a footer visible under pointer:coarse) is what caught it.
    # tags$head is hoisted into <head> by Shiny's renderer wherever the tag
    # sits in the UI, and after bootstrap.min.css so its rules win.
    tags$head(tags$link(rel = "stylesheet", href = "styles.css")),
    # Keyboard shortcuts for Trips (6.5). Loaded once here so mod_trips only
    # has to send its ids, and www/js is served as a normal Shiny resource.
    tags$script(src = "js/shortcuts.js"),
    # Section 12 glue: aria-hidden on the selects selectize hides (pa11y).
    tags$script(src = "js/a11y.js"),
    mod_header_ui("header")
  ),
  nav_panel(nav_setup,   value = "setup",   mod_setup_ui("setup")),
  nav_panel(nav_trips,   value = "trips",   mod_trips_ui("trips")),
  nav_panel(nav_results, value = "results", mod_results_ui("results")),
  nav_spacer(),
  # The dark-mode toggle is not a tab, but bslib's nav_item puts it inside
  # the same <ul role="tablist"> as the panels. These two roles are the
  # server-side half of the fix (www/js/a11y.js does the other half): they
  # remove the li's own semantics so axe does not report "listitem" for an
  # <li> whose <ul> lost its list role to tablist, and F92 on the custom
  # element. What they cannot remove is the <button> inside the component's
  # shadow root -- a tablist may only hold tabs (4.1.2) -- so a11y.js moves
  # the whole toggle out of the tablist to be its sibling. Without JS the
  # page still works and still reports one aria-required-children instead of
  # two violations.
  nav_item(
    tagAppendAttributes(input_dark_mode(id = "modo"), role = "presentation"),
    role = "presentation"
  )
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
  #
  # The same poll is also the recovery path for a call that failed mid-day
  # (mod_trip_card sets estado$resync when an answer never arrived): in
  # progress there is nothing else that could notice the screen is stale --
  # a timed-out POST /decisions is still stored server side. One GET per
  # second until one of them succeeds, and a failed GET leaves the flag set
  # so the next tick tries again.
  poll_task <- ExtendedTask$new(function(ctx, id) {
    api_async("api_get_state", ctx, id)
  })
  observe({
    req(estado$experiment_id)
    recovering <- isTRUE(estado$resync)
    req(identical(estado$status, "setup") || recovering)
    invalidateLater(1000, session)
    if (poll_task$status() != "running") {
      poll_task$invoke(estado_ctx(estado), estado$experiment_id)
    }
  })
  observe({
    res <- task_result(poll_task)
    if (!is.null(res)) {
      estado_set_state(estado, res)
      estado$resync <- FALSE
    }
  })
}

shinyApp(ui, server)
