# Step 4: the finished day (section 6.5). Phase 6 adds the share buttons,
# the feedback modal and the percentile line; this version shows the six KPIs
# the API already returns at /finish and lets the player start over.

mod_results_ui <- function(id) {
  ns <- NS(id)
  tagList(
    conditionalPanel("output.empty_on", ns = ns,
      div(class = "alert alert-light border text-center",
          textOutput(ns("empty")))),

    conditionalPanel("output.filled_on", ns = ns,
      h4(label_results_title),
      layout_columns(
        col_widths = c(4, 4, 4, 4, 4, 4),
        value_box(label_kpi_earnings, textOutput(ns("earnings")),  theme = "light"),
        value_box(label_kpi_hourly,   textOutput(ns("hourly")),    theme = "light"),
        value_box(label_kpi_vs_policy, textOutput(ns("vs_policy")), theme = "light"),
        value_box(label_kpi_accepted, textOutput(ns("accepted")),  theme = "light"),
        value_box(label_kpi_rejected, textOutput(ns("rejected")),  theme = "light"),
        value_box(label_kpi_following, textOutput(ns("following")), theme = "light")
      ),
      card(
        card_header(h4(label_history)),
        plotOutput(ns("plot_history"), height = 240)
      ),
      div(class = "text-center my-3",
        actionButton(ns("new_day"), btn_new_day, type = "primary"))
    )
  )
}

mod_results_server <- function(id, estado, reset) {
  moduleServer(id, function(input, output, session) {
    res <- reactive(estado$result)

    flag <- function(name, fn) {
      output[[name]] <- reactive(fn())
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag("empty_on",  function() is.null(res()))
    flag("filled_on", function() !is.null(res()))

    output$empty <- renderText(label_results_empty)

    money <- function(x) if (is.null(x) || is.na(x)) "--" else
      sprintf("$%.2f", as.numeric(x))
    num <- function(x, suffix = "") {
      if (is.null(x) || is.na(x)) "--" else paste0(round(as.numeric(x), 1), suffix)
    }

    output$earnings  <- renderText(money(res()$final_user_wage))
    output$hourly    <- renderText(money(res()$final_user_wage))
    output$vs_policy <- renderText({
      r <- res()
      if (is.null(r)) return("--")
      d <- as.numeric(r$final_user_wage) - as.numeric(r$final_policy_wage)
      sprintf("%s%.2f/hr", if (d >= 0) "+" else "-", abs(d))
    })
    output$accepted  <- renderText(num(res()$trips_accepted))
    output$rejected  <- renderText(num(res()$trips_rejected))
    output$following <- renderText(num(res()$pct_following_policy, "%"))

    output$plot_history <- renderPlot({
      s <- estado$state
      req(s, length(s$history) > 0)
      ensure_ggplot2()
      h <- history_df(s$history)
      line_plot(h, "user") +
        geom_line(aes(step, policy),  colour = "#6d5dfc", linetype = "dashed") +
        geom_line(aes(step, baseline), colour = "#9aa0a6", linetype = "dotted")
    })

    observeEvent(input$new_day, {
      # app.R owns the restart (it resets estado and switches the panel), so
      # this module only bumps the counter: navigating here would use the
      # module's session and target "results-nav_principal".
      reset(reset() + 1)
    })

    list()
  })
}
