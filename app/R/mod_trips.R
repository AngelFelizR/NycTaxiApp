# Step 3: accept / reject trips. Shows the API state and forwards decisions
# through non-blocking (mirai) calls. -----------------------------------------
mod_trips_ui <- function(id) {
  ns <- NS(id)
  tagList(
    layout_columns(
      col_widths = c(6, 6),
      value_box("Current Time", textOutput(ns("current_time")), theme = "light"),
      value_box("Pending Time", textOutput(ns("pending_time")), theme = "light")
    ),
    mod_results_ui(ns("results")),

    card(
      class = "bg-light",
      card_header(h4("Trip to confirm")),
      layout_columns(
        col_widths = c(4, 4, 4),
        div(strong("Trip Miles"),      textOutput(ns("trip_miles"))),
        div(strong("Trip Time (h:m)"), textOutput(ns("trip_time"))),
        div(strong("Pay $$"),          textOutput(ns("trip_pay")))
      ),
      div(strong("Current Location"), textOutput(ns("cur_location"))),
      layout_columns(
        col_widths = c(6, 6),
        div(strong("Pickup Zone"),   textOutput(ns("pickup_zone"))),
        div(strong("Drop-off Zone"), textOutput(ns("dropoff_zone")))
      ),
      leafletOutput(ns("map_trip"), height = 240),
      layout_columns(
        col_widths = c(6, 6),
        input_task_button(ns("reject"), "Reject Trip", type = "danger",
                          label_busy = "Sending...", style = "width:100%"),
        input_task_button(ns("accept"), "Accept Trip", type = "success",
                          label_busy = "Sending...", style = "width:100%")
      )
    ),

    h4("Model Results", class = "mt-3"),
    div(class = "text-success text-center",
        h4(icon("check"), " ", textOutput(ns("model_text"), inline = TRUE))),
    layout_columns(
      col_widths = c(6, 6),
      selectInput(ns("alt_pickup"),  "Change Pickup Zone",   choices = "-"),
      selectInput(ns("alt_dropoff"), "Change Drop-off Zone", choices = "-")
    ),
    card(plotOutput(ns("plot_sensitivity"), height = 300))
  )
}

mod_trips_server <- function(id, opts, day) {
  moduleServer(id, function(input, output, session) {
    state <- reactiveVal(NULL)             # latest day state returned by the API
    observeEvent(day(), state(day()))      # new day -> initial state

    observeEvent(opts(), {
      z <- opts()$zones
      updateSelectInput(session, "alt_pickup",  choices = c("-", z))
      updateSelectInput(session, "alt_dropoff", choices = c("-", z))
    })

    # --- decisions: one in-flight request at a time, buttons show busy state ---
    decision_task <- ExtendedTask$new(function(day_id, accept) {
      api_async("api_decide", day_id, accept)
    })
    bind_task_button(decision_task, "accept")
    bind_task_button(decision_task, "reject")

    send_decision <- function(accept) {
      req(state())
      if (decision_task$status() == "running") return()   # ignore double clicks
      decision_task$invoke(state()$day_id, accept)
    }
    observeEvent(input$accept, send_decision(TRUE))
    observeEvent(input$reject, send_decision(FALSE))
    observe({
      res <- task_result(decision_task)
      if (!is.null(res)) state(res)
    })

    trip <- reactive({ req(state()); state()$trip })

    output$current_time <- renderText({ req(state()); state()$clock })
    output$pending_time <- renderText({ req(state()); sprintf("%.1f hours", state()$pending_hours) })
    output$trip_miles   <- renderText(trip()$miles)
    output$trip_time    <- renderText(sprintf("%02.0f:%02.0f", trip()$minutes %/% 60, trip()$minutes %% 60))
    output$trip_pay     <- renderText(trip()$pay)
    output$cur_location <- renderText(trip()$current_location)
    output$pickup_zone  <- renderText(trip()$pickup_zone)
    output$dropoff_zone <- renderText(trip()$dropoff_zone)
    output$model_text   <- renderText(paste0(tools::toTitleCase(trip()$recommendation), " trip"))
    output$map_trip     <- renderLeaflet(basemap())

    # --- sensitivity: re-requested when the state or the selectors change ---
    sens_task <- ExtendedTask$new(function(day_id, pickup, dropoff) {
      api_async("api_sensitivity", day_id, pickup, dropoff)
    })
    observe({
      req(state(), !isTRUE(state()$finished))
      sens_task$invoke(state()$day_id,
                       zone_or_null(input$alt_pickup),
                       zone_or_null(input$alt_dropoff))
    }) |> bindEvent(state(), input$alt_pickup, input$alt_dropoff)
    sensitivity <- reactive(task_result(sens_task))

    output$plot_sensitivity <- renderPlot({
      s <- sensitivity(); req(s)
      ggplot(s, aes(trip_minutes, min_pay, colour = scenario)) +
        geom_line() +
        labs(title = "Decision-boundary sensitivity to pickup and drop-off zones",
             x = "Trip time (min)", y = "Minimum pay to accept ($)", colour = NULL) +
        theme_minimal()
    })

    mod_results_server("results", state)

    list(state = state, finished = reactive(isTRUE(state()$finished)))
  })
}
