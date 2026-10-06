# The offer on the table (6.5): what the player is deciding, a map with the
# route, and the Accept/Reject pair.
#
# The map is rendered once and then only touched through leafletProxy(), so a
# new offer never resets the zoom or the pan the player chose. The decision
# itself is an ExtendedTask (mirai) -- the button stays busy until the API
# answers, and the resulting DayState goes back into `estado`, which is the
# single source of truth for every module in the session.

mod_trip_card_ui <- function(id) {
  ns <- NS(id)
  tagList(
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
        div(strong(label_pickup_zone),  textOutput(ns("pickup_zone"))),
        div(strong(label_dropoff_zone), textOutput(ns("dropoff_zone")))
      ),
      leafletOutput(ns("map_trip"), height = 240),
      div(class = "text-center text-muted my-2", textOutput(ns("model_text"))),
      div(class = "trip-actions",
        input_task_button(ns("reject"), btn_reject, type = "danger",
                          label_busy = btn_busy),
        input_task_button(ns("accept"), btn_accept, type = "success",
                          label_busy = btn_busy)
      )
    )
  )
}

mod_trip_card_server <- function(id, estado, dark) {
  moduleServer(id, function(input, output, session) {
    # The offer, normalised by current_trip() so NULL/NA/{} all mean the same.
    trip <- reactive(current_trip(estado))

    # --- decisions: one in-flight request at a time (buttons show busy) -------
    decision_task <- ExtendedTask$new(function(ctx, exp_id, trip_id, accept) {
      api_async("api_decide", ctx, exp_id, trip_id, accept)
    })
    bind_task_button(decision_task, "accept")
    bind_task_button(decision_task, "reject")

    send_decision <- function(accept) {
      req(trip(), identical(estado$status, "in_progress"))
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

    # --- map: zones once, tiles follow the theme, route per offer ------------
    # renderLeaflet draws the initial view (zones + the offer as it stands).
    # Everything afterwards goes through leafletProxy, which is only safe once
    # the widget has bound on the client -- sending earlier logs
    # "Couldn't find map with id ..." because the Trips panel is still hidden.
    map_ready <- reactiveVal(FALSE)

    output$map_trip <- renderLeaflet({
      z <- zones_map_data()
      m <- basemap()
      base <- if (is.null(z)) m else
        addPolygons(m, data = z, weight = 1, color = "#e3e6ea",
                    fillColor = "#ffffff", fillOpacity = 0.5,
                    options = pathOptions(clickable = FALSE))
      map_ready(TRUE)
      draw_route(base, trip(), z)
    })

    # 6.5: the tile layer switches with the theme without reloading the widget,
    # so the current centre and zoom survive the toggle.
    observeEvent(dark(), {
      req(map_ready())
      leafletProxy("map_trip", session) |>
        addProviderTiles(if (isTRUE(dark())) "CartoDB.DarkMatter"
                         else "CartoDB.Positron")
    })

    observe({
      req(map_ready())
      proxy <- leafletProxy("map_trip", session) |> clearGroup("route")
      draw_route(proxy, trip(), zones_map_data())
    })

    # --- fields ---------------------------------------------------------------
    output$trip_miles   <- renderText({ t <- trip(); if (is.null(t)) "" else t$miles })
    output$trip_time    <- renderText({
      t <- trip()
      if (is.null(t)) return("")
      secs <- as.numeric(t$trip_time_sec %||% 0)
      sprintf("%02.0f:%02.0f", secs %/% 3600, (secs %% 3600) %/% 60)
    })
    output$trip_pay     <- renderText({ t <- trip(); if (is.null(t)) "" else t$driver_pay })
    output$cur_location <- renderText({ estado$state$current_zone %||% "" })
    output$pickup_zone  <- renderText({ t <- trip(); t$pickup_zone %||% "" })
    output$dropoff_zone <- renderText({ t <- trip(); t$dropoff_zone %||% "" })
    output$model_text   <- renderText({
      t <- trip()
      if (is.null(t)) return("")
      # Recommendation is an enum in the contract, so it maps to copy that
      # already lives in strings.R rather than being re-cased here.
      switch(t$recommendation %||% "",
             accept = label_model_accept,
             reject = label_model_reject,
             "")
    })

    # The ids the keyboard shortcuts drive: mod_trips owns the key handler and
    # must not have to guess this module's namespace.
    list(trip = trip,
         accept_id = session$ns("accept"),
         reject_id = session$ns("reject"))
  })
}

# The offer drawn on the map. Works both on the renderLeaflet result and on a
# leafletProxy (the caller clears the "route" group first), so the initial
# paint and every later offer go through the same code.
draw_route <- function(map, t, z) {
  if (is.null(t) || is.null(z)) return(map)
  pts <- zone_points(z, c(t$pulocation_id, t$dolocation_id))
  if (is.null(pts) || nrow(pts) == 0) return(map)
  coords <- sf::st_coordinates(sf::st_geometry(pts))
  route <- data.frame(lng = coords[, 1], lat = coords[, 2])
  map |>
    addPolylines(data = route, lng = ~lng, lat = ~lat, group = "route",
                 weight = 3, color = "#6d5dfc", opacity = 0.7) |>
    addCircleMarkers(data = route, lng = ~lng, lat = ~lat, group = "route",
                     radius = 6, stroke = FALSE, fillOpacity = 0.9,
                     fillColor = if (nrow(route) >= 2)
                       c("#8470ff", "#C44E52") else "#8470ff")
}
