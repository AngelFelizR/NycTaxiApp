# What-if zone picker (6.5): change the pickup or the drop-off and see how the
# model's decision boundary moves.
#
# 263 zones never reach the client as a list: updateSelectizeInput(server =
# TRUE) answers the search query from the server instead. The boundary is a
# girafe (interactive) heatmap of P(accept) over trip time x driver pay -- a
# probability ramp, not a performance comparison, so section 3.11 still holds.

mod_sensitivity_ui <- function(id) {
  ns <- NS(id)
  tagList(
    h4(label_sensitivity, class = "mt-3"),
    div(class = "text-muted small text-center", textOutput(ns("ctx"))),
    div(class = "d-flex gap-2 mt-2",
      selectizeInput(ns("pickup"), label_pu_selector,
                     choices = c("-" = "-"),
                     options = list(placeholder = label_zone_placeholder)),
      selectizeInput(ns("dropoff"), label_do_selector,
                     choices = c("-" = "-"),
                     options = list(placeholder = label_zone_placeholder))
    ),
    conditionalPanel("output.idle_on", ns = ns,
      div(class = "text-center text-muted small", textOutput(ns("idle")))),
    conditionalPanel("output.plot_on", ns = ns,
      card(ggiraph::girafeOutput(ns("plot"), height = 320)))
  )
}

mod_sensitivity_server <- function(id, estado, reset) {
  moduleServer(id, function(input, output, session) {
    trip <- reactive(current_trip(estado))
    sensitivity <- reactiveVal(NULL)

    # Server-side choices: the client never receives all 263 labels at once.
    observe({
      ch <- zone_select_choices()
      updateSelectizeInput(session, "pickup",  choices = ch, server = TRUE)
      updateSelectizeInput(session, "dropoff", choices = ch, server = TRUE)
    })

    clear <- function() {
      sensitivity(NULL)
      updateSelectizeInput(session, "pickup",  selected = "-")
      updateSelectizeInput(session, "dropoff", selected = "-")
    }

    observeEvent(reset(), clear(), ignoreInit = TRUE)

    sens_task <- ExtendedTask$new(
      function(ctx, exp_id, trip_id, pu, do_) {
        api_async("api_sensitivity", ctx, exp_id, trip_id, pu, do_)
      })

    # One boundary per offer: a new trip invalidates whatever was on screen.
    observeEvent(list(estado$experiment_id, trip()$trip_id %||% 0),
                 sensitivity(NULL), ignoreInit = TRUE)
    observeEvent(list(estado$status), {
      if (!identical(estado$status, "in_progress")) clear()
    }, ignoreInit = TRUE)

    observeEvent(list(input$pickup, input$dropoff), {
      req(trip(), identical(estado$status, "in_progress"))
      if (sens_task$status() == "running") return()
      sens_task$invoke(estado_ctx(estado), estado$experiment_id,
                       trip()$trip_id,
                       zone_or_null(input$pickup),
                       zone_or_null(input$dropoff))
    }, ignoreInit = TRUE)

    observe({
      res <- task_result(sens_task)
      if (!is.null(res)) sensitivity(res)
    })

    # --- flags ---------------------------------------------------------------
    flag <- function(name, fn) {
      output[[name]] <- reactive(fn())
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag("plot_on",  function() !is.null(sensitivity()))
    flag("idle_on",  function() is.null(sensitivity()))

    output$idle <- renderText(label_sensitivity_idle)
    output$ctx  <- renderText({
      s <- sensitivity()
      if (!is.null(s) && !is.null(s$meta) && nzchar(s$meta$original_label %||% "")) {
        return(s$meta$original_label)
      }
      t <- trip()
      if (is.null(t)) return("")
      sprintf("%s \u2192 %s", t$pickup_zone %||% "?", t$dropoff_zone %||% "?")
    })

    # --- the boundary ---------------------------------------------------------
    output$plot <- ggiraph::renderGirafe({
      s <- sensitivity()
      req(s)
      g <- grid_df(s$grid_original)
      req(nrow(g) > 0)
      ensure_ggplot2()
      p <- ggplot2::ggplot(g, ggplot2::aes(x = trip_time_sec, y = driver_pay,
                                           fill = prob)) +
        ggiraph::geom_tile_interactive(
          ggplot2::aes(tooltip = sprintf("%.0f s \u00b7 $%.2f \u2192 %.0f%%",
                                         trip_time_sec, driver_pay, 100 * prob)),
          colour = "white", linewidth = 0.2
        ) +
        ggplot2::scale_fill_gradient(low = "#f6f7f9", high = brand_colour(),
                                     limits = c(0, 1), name = "P(accept)") +
        ggplot2::labs(x = "Trip time (s)", y = "Driver pay ($)",
                      title = label_sensitivity_plot) +
        ggplot2::theme_minimal()
      # options takes a LIST of option objects; girafe_options() modifies an
      # existing girafe, so wrapping each option in it makes girafe() reject
      # the widget with "`x` must be a girafe object".
      ggiraph::girafe(ggobj = p, options = list(
        ggiraph::opts_toolbar(saveaspng = FALSE),
        ggiraph::opts_hover(css = "stroke-width:3px;")
      ))
    })

    list(sensitivity = sensitivity)
  })
}
