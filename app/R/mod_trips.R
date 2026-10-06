# Step 3: accept / reject trips (section 6.5). Shows the DayState the API
# returns and forwards decisions through non-blocking (mirai) calls.
#
# While the day is still in "setup" the policy/baseline trajectories are being
# computed in the background (4.6): the panel says so and app.R polls /state.

mod_trips_ui <- function(id) {
  ns <- NS(id)
  tagList(
    conditionalPanel("output.idle_on", ns = ns,
      div(class = "alert alert-light border text-center", textOutput(ns("idle")))),

    conditionalPanel("output.ready_on", ns = ns,
      layout_columns(
        col_widths = c(6, 6),
        value_box(label_current_time, textOutput(ns("current_time")),
                  theme = "light"),
        value_box(label_pending_time, textOutput(ns("pending_time")),
                  theme = "light")
      ),

      card(
        class = "bg-light",
        card_header(h4(label_trip_card)),
        layout_columns(
          col_widths = c(4, 4, 4),
          div(strong(label_trip_miles), textOutput(ns("trip_miles"))),
          div(strong(label_trip_time),  textOutput(ns("trip_time"))),
          div(strong(label_trip_pay),   textOutput(ns("trip_pay")))
        ),
        div(strong(label_current_location), textOutput(ns("cur_location"))),
        layout_columns(
          col_widths = c(6, 6),
          div(strong(label_pickup_zone),   textOutput(ns("pickup_zone"))),
          div(strong(label_dropoff_zone),  textOutput(ns("dropoff_zone")))
        ),
        leafletOutput(ns("map_trip"), height = 240),
        layout_columns(
          col_widths = c(6, 6),
          input_task_button(ns("reject"), btn_reject, type = "danger",
                            label_busy = btn_busy, style = "width:100%; min-height:44px"),
          input_task_button(ns("accept"), btn_accept, type = "success",
                            label_busy = btn_busy, style = "width:100%; min-height:44px")
        )
      ),

      h4(label_sensitivity, class = "mt-3"),
      div(class = "text-center text-muted", textOutput(ns("model_text"))),

      card(
        card_header(h4(label_history)),
        plotOutput(ns("plot_history"), height = 220)
      ),

      div(class = "d-flex gap-2 mt-2",
        selectizeInput(ns("alt_pickup"),  label_pu_selector, choices = "-"),
        selectizeInput(ns("alt_dropoff"), label_do_selector, choices = "-")
      ),
      conditionalPanel("output.sens_on", ns = ns,
        card(plotOutput(ns("plot_sensitivity"), height = 260)))
    )
  )
}

mod_trips_server <- function(id, estado, reset) {
  moduleServer(id, function(input, output, session) {
    st <- reactive(estado$state)

    # Zone selectors: "-" keeps the original zone (zone_or_null maps it to NULL).
    observe({
      ch <- zone_choices()
      if (length(ch) == 0) ch <- c("-" = "-")
      choices <- c("-" = "-", ch)
      updateSelectizeInput(session, "alt_pickup",  choices = choices)
      updateSelectizeInput(session, "alt_dropoff", choices = choices)
    })

    observeEvent(reset(), {
      updateSelectizeInput(session, "alt_pickup",  selected = "-")
      updateSelectizeInput(session, "alt_dropoff", selected = "-")
    }, ignoreInit = TRUE)

    observeEvent(list(estado$status, estado$experiment_id), {
      if (!identical(estado$status, "in_progress")) {
        updateSelectizeInput(session, "alt_pickup",  selected = "-")
        updateSelectizeInput(session, "alt_dropoff", selected = "-")
      }
    }, ignoreInit = TRUE)

    # --- decisions: one in-flight request at a time, buttons show busy state ---
    decision_task <- ExtendedTask$new(function(ctx, exp_id, trip_id, accept) {
      api_async("api_decide", ctx, exp_id, trip_id, accept)
    })
    sens_task <- ExtendedTask$new(
      function(ctx, exp_id, trip_id, pu, do_) {
        api_async("api_sensitivity", ctx, exp_id, trip_id, pu, do_)
      })
    sensitivity <- reactiveVal(NULL)

    bind_task_button(decision_task, "accept")
    bind_task_button(decision_task, "reject")

    # The offer on the table. next_trip is null while the day is in setup and
    # once it is over; depending on how the JSON was parsed that arrives as
    # NULL, NA or an empty object, so all three mean "no trip".
    trip <- reactive({
      s <- st()
      if (is.null(s)) return(NULL)
      t <- s$next_trip
      if (!is.list(t) || length(t) == 0 || is.null(t$trip_id)) return(NULL)
      t
    })

    send_decision <- function(accept) {
      req(trip())
      if (decision_task$status() == "running") return()   # ignore double clicks
      decision_task$invoke(estado_ctx(estado), estado$experiment_id,
                           trip()$trip_id, accept)
    }
    observeEvent(input$accept, send_decision(TRUE))
    observeEvent(input$reject, send_decision(FALSE))
    observe({
      res <- task_result(decision_task)
      if (!is.null(res)) estado_set_state(estado, res)
    })

    # --- sensitivity: only for the trip on screen, only once per offer --------
    observeEvent(list(input$alt_pickup, input$alt_dropoff), {
      req(trip(), identical(estado$status, "in_progress"))
      if (sens_task$status() == "running") return()
      sens_task$invoke(estado_ctx(estado), estado$experiment_id,
                       trip()$trip_id,
                       zone_or_null(input$alt_pickup),
                       zone_or_null(input$alt_dropoff))
    }, ignoreInit = TRUE)
    observe({
      res <- task_result(sens_task)
      if (!is.null(res)) sensitivity(res)
    })
    observeEvent(list(estado$experiment_id, trip()$trip_id %||% 0),
                 sensitivity(NULL), ignoreInit = TRUE)

    # --- derived flags --------------------------------------------------------
    flag <- function(name, fn) {
      output[[name]] <- reactive(fn())
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag("idle_on", function() {
      s <- st()
      is.null(s) || !identical(estado$status, "in_progress")
    })
    flag("ready_on", function() {
      identical(estado$status, "in_progress") && !is.null(trip())
    })
    flag("sens_on", function() !is.null(sensitivity()))

    output$idle <- renderText({
      if (identical(estado$status, "setup")) label_trips_idle
      else if (is.null(st())) label_no_day
      else label_no_trip
    })

    output$current_time <- renderText({ s <- st(); s$clock %||% "" })
    output$pending_time <- renderText({
      s <- st()
      if (is.null(s)) return("")
      sprintf("%.1f hours", s$pending_hours %||% 0)
    })
    output$trip_miles   <- renderText({ t <- trip(); if (is.null(t)) "" else t$miles })
    output$trip_time    <- renderText({
      t <- trip()
      if (is.null(t)) return("")
      secs <- as.numeric(t$trip_time_sec %||% 0)
      sprintf("%02.0f:%02.0f", secs %/% 3600, (secs %% 3600) %/% 60)
    })
    output$trip_pay     <- renderText({ t <- trip(); if (is.null(t)) "" else t$driver_pay })
    output$cur_location <- renderText({ s <- st(); s$current_zone %||% "" })
    output$pickup_zone  <- renderText({ t <- trip(); t$pickup_zone %||% "" })
    output$dropoff_zone <- renderText({ t <- trip(); t$dropoff_zone %||% "" })
    output$model_text   <- renderText({
      t <- trip()
      if (is.null(t)) return("")
      paste0(tools::toTitleCase(t$recommendation %||% ""), " trip")
    })

    output$map_trip <- renderLeaflet({
      z <- zones_map_data()
      m <- basemap()
      t <- trip()
      if (is.null(z)) return(m)
      base <- addPolygons(m, data = z, weight = 1, color = "#e3e6ea",
                          fillColor = "#ffffff", fillOpacity = 0.5,
                          options = pathOptions(clickable = FALSE))
      pts <- if (is.null(t)) NULL else zone_points(z, c(t$pulocation_id,
                                                        t$dolocation_id))
      if (is.null(pts) || nrow(pts) == 0) return(base)
      coords <- sf::st_coordinates(sf::st_geometry(pts))
      route <- data.frame(lng = coords[, 1], lat = coords[, 2])
      base |>
        addPolylines(data = route, lng = ~lng, lat = ~lat,
                     weight = 3, color = "#6d5dfc", opacity = 0.7) |>
        addCircleMarkers(data = route, lng = ~lng, lat = ~lat, radius = 6,
                         stroke = FALSE, fillOpacity = 0.9,
                         fillColor = if (nrow(route) >= 2)
                           c("#8470ff", "#C44E52") else "#8470ff")
    })

    output$plot_history <- renderPlot({
      s <- st()
      req(s, length(s$history) > 0)
      ensure_ggplot2()
      h <- history_df(s$history)
      p <- line_plot(h, "user") +
        geom_line(aes(step, policy),  colour = "#6d5dfc", linetype = "dashed") +
        geom_line(aes(step, baseline), colour = "#9aa0a6", linetype = "dotted") +
        labs(colour = NULL)
      p
    })

    output$plot_sensitivity <- renderPlot({
      s <- sensitivity()
      req(s)
      g <- grid_df(s$grid_original)
      req(nrow(g) > 0)
      ensure_ggplot2()
      ggplot(g, aes(trip_time_sec, driver_pay, colour = prob)) +
        geom_point(size = 1.4) +
        scale_colour_gradient(low = "#e3e6ea", high = "#6d5dfc",
                              name = "P(accept)") +
        labs(x = "Trip time (sec)", y = "Driver pay ($)",
             title = label_sensitivity_plot) +
        theme_minimal()
    })

    list(finished = reactive(identical(estado$status, "finished")))
  })
}

# --- small adapters over the contract payloads (kept next to their only user)

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
# `simplifyVector` may hand them over as a data.frame or as a list of rows.
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

# Centroids of the requested LocationIDs, in WGS84, in the given order.
zone_points <- function(z, ids) {
  ids <- ids[!is.na(ids) & !is.null(ids)]
  if (length(ids) == 0) return(NULL)
  sel <- z[as.character(z$LocationID) %in% as.character(ids), ]
  if (nrow(sel) == 0) return(NULL)
  pts <- suppressWarnings(sf::st_point_on_surface(sf::st_geometry(sel)))
  coords <- sf::st_coordinates(pts)
  sel$lng <- coords[, 1]
  sel$lat <- coords[, 2]
  # Order as requested so the colours (PU then DO) match.
  ord <- match(as.character(ids), as.character(sel$LocationID))
  sel <- sel[stats::na.omit(ord), ]
  if (nrow(sel) == 0) NULL else sel
}
