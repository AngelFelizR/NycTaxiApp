# Decide as Taxi Driver For A Day -- thin Shiny client for a plumber2 API.
# UI + non-blocking API calls (httr2 running in mirai daemons). No domain logic here.
# install.packages(c("shiny", "bslib", "leaflet", "ggplot2", "httr2", "mirai"))
# API location:  Sys.setenv(TAXI_API_URL = "http://127.0.0.1:8000")

library(shiny)
library(bslib)
library(leaflet)
library(ggplot2)
library(httr2)
library(mirai)

# Background workers, shared by all sessions of this R process. They load the
# Shiny-free API client once, so each request only ships its arguments.
daemons(4)
everywhere({
  library(httr2)
  source(api_file)
}, api_file = normalizePath("R/api_client.R"))
onStop(function() daemons(0))

ui <- page_fluid(
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  title = "Decide as Taxi Driver For A Day",
  tags$head(tags$link(rel = "stylesheet", href = "styles.css")),

  div(class = "container", style = "max-width: 720px;",
    h3("Decide as Taxi Driver For A Day", class = "mt-3"),
    navset_hidden(
      id = "step",
      nav_panel_hidden("setup",     mod_setup_ui("setup")),
      nav_panel_hidden("trips",     mod_trips_ui("trips")),
      nav_panel_hidden("dashboard", mod_dashboard_ui("dashboard"))
    )
  )
)

server <- function(input, output, session) {
  # Options (companies, zones, defaults) are fetched once per session, async
  opts_task <- ExtendedTask$new(function() api_async("api_options"))
  opts_task$invoke()
  opts <- reactive(task_result(opts_task))

  restart <- reactiveVal(0)
  setup <- mod_setup_server("setup", opts = opts, reset = restart)
  trips <- mod_trips_server("trips", opts = opts, day = setup$day)
  dash  <- mod_dashboard_server("dashboard", state = trips$state)

  # The only place that knows the flow between steps
  observeEvent(setup$day(), nav_select("step", "trips"), ignoreInit = TRUE)
  observeEvent(trips$finished(), {
    if (trips$finished()) nav_select("step", "dashboard")
  }, ignoreInit = TRUE)
  observeEvent(dash$restart(), {
    restart(restart() + 1)
    nav_select("step", "setup")
  }, ignoreInit = TRUE)
}

shinyApp(ui, server)
