# Step 4: the finished day (6.5, 4.6).
#
# Six KPIs maximum -- the percentile is a sentence under the curves, never a
# seventh one (4.6). This is the one screen where colour is allowed: the
# difference against the model carries green/red AND an arrow AND the number,
# so nothing depends on colour alone (3.11).

# One KPI cell: label left, value right (same shape as the Trips sidebar).
result_kpi <- function(ns, label, output) {
  div(class = "kpi-row",
    span(class = "kpi-label", label),
    span(class = "kpi-value", textOutput(ns(output), inline = TRUE)))
}

mod_results_ui <- function(id) {
  ns <- NS(id)
  tagList(
    conditionalPanel("output.empty_on", ns = ns,
      div(class = "alert alert-light border text-center", textOutput(ns("empty")))),

    conditionalPanel("output.filled_on", ns = ns,
      div(class = "d-flex align-items-center gap-2 flex-wrap",
        h4(label_results_title, class = "mb-0"),
        conditionalPanel("output.seed_on", ns = ns,
          span(class = "badge text-bg-warning custom-seed", badge_custom_seed))),
      conditionalPanel("output.norides_on", ns = ns,
        div(class = "alert alert-light border mt-2", textOutput(ns("no_rides")))),

      layout_columns(
        col_widths = breakpoints(xs = c(12, 12, 12, 12, 12, 12),
                                 md = c(6, 6, 6, 6, 6, 6),
                                 lg = c(4, 4, 4, 4, 4, 4)),
        result_kpi(ns, label_kpi_earnings, "earnings"),
        result_kpi(ns, label_kpi_hourly, "hourly"),
        # The comparison is the only coloured cell: green/red + arrow + number
        # (3.11). One textOutput only -- rendering it twice would duplicate the
        # HTML id -- so the colour lives on the wrapper and shinyjs swaps it.
        div(class = "kpi-row",
          span(class = "kpi-label", label_kpi_vs_policy),
          div(class = "kpi-value", id = ns("vs_policy_box"),
              textOutput(ns("vs_policy"), inline = TRUE))),
        result_kpi(ns, label_kpi_accepted, "accepted"),
        result_kpi(ns, label_kpi_rejected, "rejected"),
        result_kpi(ns, label_kpi_following, "following")
      ),

      card(
        card_header(h4(label_history)),
        # Section 12: role="img" + a label, or the chart is invisible to a
        # screen reader.
        div(role = "img", `aria-label` = label_history_aria,
            ggiraph::girafeOutput(ns("plot_history"), height = 280))
      ),
      div(class = "text-center mt-2", textOutput(ns("percentile"))),
      div(class = "text-center text-muted small", textOutput(ns("percentile_note"))),

      tags$details(class = "mt-3",
        tags$summary(label_technical),
        div(class = "kpi-row",
          span(class = "kpi-label", label_experiment_id),
          span(class = "kpi-value", textOutput(ns("exp_id"), inline = TRUE))),
        div(class = "kpi-row",
          span(class = "kpi-label", label_company_detail),
          span(class = "kpi-value", textOutput(ns("company"), inline = TRUE))),
        div(class = "kpi-row",
          span(class = "kpi-label", label_model_version),
          span(class = "kpi-value", textOutput(ns("model_version"), inline = TRUE)))
      ),

      # 6.5: the four share buttons plus the second email prompt live in their
      # own module so mod_results stays about the result itself.
      mod_share_ui(ns("share")),

      div(class = "text-center my-3 d-flex gap-2 justify-content-center flex-wrap",
        actionButton(ns("feedback"), label_feedback_btn,
                     icon = icon("comment"), class = "btn-outline-secondary"),
        actionButton(ns("new_day"), btn_new_day, type = "primary"))
    )
  )
}

mod_results_server <- function(id, estado, reset) {
  moduleServer(id, function(input, output, session) {
    res  <- reactive(estado$result)
    exp  <- reactive(estado$experiment)
    st   <- reactive(estado$state)

    feedback <- mod_feedback_server("feedback", estado)
    mod_share_server("share", estado)

    # Every output lives inside a conditionalPanel, so each one has to opt out
    # of suspension: an output that only computes once it is visible would
    # still be blank when the panel is shown by a flag it cannot see.
    keep <- function(name, expr) {
      output[[name]] <- expr
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag <- function(name, fn) {
      keep(name, reactive(fn()))
    }
    flag("empty_on",  function() is.null(res()))
    flag("filled_on", function() !is.null(res()))
    flag("seed_on",   function() isTRUE(exp()$seed_is_custom))
    flag("norides_on", function() {
      r <- res()
      !is.null(r) && as.numeric(r$trips_accepted %||% 0) == 0
    })

    # Colour is never the only signal: the arrow and the number stay in the
    # text (3.11); this only picks the hue of the wrapper.
    observe({
      r <- res()
      better <- if (is.null(r)) TRUE else
        as.numeric(r$final_user_wage) - as.numeric(r$final_policy_wage) >= 0
      shinyjs::runjs(sprintf(
        "var e=document.getElementById('%s'); if(e){e.className='kpi-value %s';}",
        session$ns("vs_policy_box"), if (better) "text-success" else "text-danger"
      ))
    })

    keep("empty",   renderText(label_results_empty))
    keep("no_rides", renderText(msg_no_rides))

    # --- KPIs ----------------------------------------------------------------
    money <- function(x) {
      if (is.null(x) || length(x) == 0 || is.na(x[1])) "--"
      else sprintf("$%.2f", as.numeric(x[1]))
    }
    whole <- function(x, suffix = "") {
      if (is.null(x) || length(x) == 0 || is.na(x[1])) "--"
      else paste0(as.integer(round(as.numeric(x[1]))), suffix)
    }

    # Total earnings are the last cumulative point of the player's curve --
    # the API's wages are hourly, so the total is not in the result payload.
    keep("earnings", renderText({
      s <- st()
      if (is.null(s) || length(s$history) == 0) return("--")
      h <- history_df(s$history)
      money(h$user[length(h$user)])
    }))
    keep("hourly", renderText(money(res()$final_user_wage)))

    # Section 6.5: always in an interpretable unit, and with the percentage
    # when the model's wage makes one meaningful. Green/red only ever paired
    # with the arrow and the number (3.11).
    keep("vs_policy", renderText({
      r <- res()
      if (is.null(r)) return("--")
      d <- as.numeric(r$final_user_wage) - as.numeric(r$final_policy_wage)
      base <- as.numeric(r$final_policy_wage)
      pct_part <- if (is.finite(base) && base > 0) {
        sprintf(" (%+.1f%%)", 100 * d / base)
      } else {
        ""
      }
      sprintf("%s$%.2f/hr%s %s", if (d >= 0) "+" else "-", abs(d), pct_part,
              if (d >= 0) "\u25b2" else "\u25bc")
    }))
    keep("accepted",  renderText(whole(res()$trips_accepted)))
    keep("rejected",  renderText(whole(res()$trips_rejected)))
    keep("following", renderText(whole(res()$pct_following_policy)))

    # --- percentile: a sentence under the curves, never a KPI (4.6) ----------
    keep("percentile", renderText({
      r <- res()
      if (is.null(r) || is.null(r$user_percentile) || is.na(r$user_percentile)) {
        return("")
      }
      sprintf(fmt_percentile, ordinal(r$user_percentile))
    }))
    keep("percentile_note", renderText(note_percentile))

    # --- technical details (6.5: never a KPI, always reachable) --------------
    keep("exp_id",        renderText(estado$experiment_id %||% "--"))
    keep("company",       renderText(exp()$company %||% "--"))
    keep("model_version", renderText(exp()$model_version %||% "--"))

    # --- the three curves ----------------------------------------------------
    output$plot_history <- ggiraph::renderGirafe({
      s <- st()
      req(s, length(s$history) > 0)
      ensure_ggplot2()
      h <- history_df(s$history)
      n <- nrow(h)
      req(n > 0)
      long <- data.frame(
        step = rep(h$step, 3),
        series = factor(rep(c(label_curve_user, label_curve_policy,
                              label_curve_baseline), each = n),
                        levels = c(label_curve_user, label_curve_policy,
                                   label_curve_baseline)),
        value = c(h$user, h$policy, h$baseline)
      )
      # Already named by legend label, which is what scale_colour_manual looks
      # up -- shared/load.R guarantees the names match the data's levels.
      cols <- curve_colours()
      p <- ggplot2::ggplot(long, ggplot2::aes(step, value, colour = series)) +
        ggiraph::geom_line_interactive(
          ggplot2::aes(tooltip = sprintf("%s \u00b7 after %d decisions \u00b7 $%.2f",
                                         series, step, value),
                       data_id = series),
          linewidth = 1.2
        ) +
        ggplot2::scale_colour_manual(values = cols, name = NULL) +
        ggplot2::labs(x = "Decisions", y = "Cumulative pay ($)") +
        ggplot2::theme_minimal() +
        ggplot2::theme(legend.position = "bottom")
      # options takes a LIST of option objects; girafe_options() is the
      # in-place modifier and needs the girafe as its first argument, so
      # wrapping each option in it makes girafe() reject the widget.
      ggiraph::girafe(ggobj = p, options = list(
        ggiraph::opts_toolbar(saveaspng = FALSE),
        ggiraph::opts_hover(css = "stroke-width:3px;")
      ))
    })

    # --- actions -------------------------------------------------------------
    observeEvent(input$feedback, feedback$open())
    observeEvent(input$new_day, reset(reset() + 1))

    list()
  })
}
