# The Trips screen (6.5): sidebar KPIs + the clock, the offer, the cumulative
# chart and the what-if zone picker.
#
# Layout: layout_columns with breakpoints(md = c(12, 12), lg = c(3, 9)) -- one
# column on small screens, 3/9 on large. NOTE the master doc writes this as
# `col_widths = c(3, 9), breakpoints = breakpoints(...)`; on bslib 0.12.0 that
# extra argument lands in `...` and becomes a useless `breakpoints=` attribute
# while the md/lg widths are dropped. The breakpoints object IS the col_widths
# (see CHANGELOG). Divergence annotated, document untouched.
#
# Section 3.11: nothing here may compare the player to the model. The three
# curves are drawn in neutral hues (purple for the player, two greys), there is
# no delta, no traffic light, and the sidebar shows no running % vs policy.

mod_trips_ui <- function(id) {
  ns <- NS(id)
  tagList(
    conditionalPanel("output.idle_on", ns = ns,
      div(class = "alert alert-light border text-center", textOutput(ns("idle")))),

    conditionalPanel("output.ready_on", ns = ns,
      layout_columns(
        col_widths = breakpoints(md = c(12, 12), lg = c(3, 9)),

        # ---- sidebar ---------------------------------------------------------
        div(class = "trips-sidebar",
          div(class = "kpi-row",
            span(class = "kpi-label", label_current_time),
            span(class = "kpi-value", textOutput(ns("current_time"), inline = TRUE))),
          div(class = "kpi-row",
            span(class = "kpi-label", label_earnings),
            span(class = "kpi-value", textOutput(ns("earnings"), inline = TRUE))),
          div(class = "kpi-row",
            span(class = "kpi-label", label_decisions),
            span(class = "kpi-value", textOutput(ns("decisions"), inline = TRUE))),

          h6(label_pending_time, class = "mt-3 mb-0"),
          # Static DOM (6.1.1: no renderUI for structure). The width and the
          # colour level are pushed with shinyjs; only the hours are content.
          div(class = "pending-bar",
            div(id = ns("pending_fill"), class = "pending-fill pending-ok",
                style = "width:100%"),
            span(class = "pending-label",
                 textOutput(ns("pending_hours"), inline = TRUE))),

          actionButton(ns("resume"), label_resume_code_btn,
                       icon = icon("key"), class = "btn-sm btn-outline-secondary w-100")
        ),

        # ---- main ------------------------------------------------------------
        div(class = "trips-main",
          mod_trip_card_ui(ns("card")),

          card(
            card_header(h4(label_history)),
            ggiraph::girafeOutput(ns("plot_history"), height = 260)
          ),

          mod_sensitivity_ui(ns("sensitivity")),

          div(class = "kbd-footer",
            span(class = "kbd-hints d-inline-flex align-items-center gap-1",
              icon("keyboard"),
              span(class = "kbd-key", icon("arrow-left")),  span(kbd_arrow_left),
              span(class = "kbd-sep"), span(class = "kbd-key", icon("arrow-right")),
              span(kbd_arrow_right),
              span(class = "kbd-sep"), span(class = "kbd-key", "Enter"),
              span(kbd_enter),
              span(class = "kbd-sep"), span(class = "kbd-key", "?"),
              span(kbd_question)),
            actionButton(ns("help"), "", icon = icon("circle-question"),
                         class = "btn-sm btn-outline-secondary ms-auto",
                         title = kbd_title)
          )
        )
      )
    )
  )
}

mod_trips_server <- function(id, estado, reset, dark) {
  moduleServer(id, function(input, output, session) {
    st <- reactive(estado$state)
    # `ns` only exists in the UI function; in the server the namespace is the
    # session's. Resolved once, outside the observer.
    fill_id <- session$ns("pending_fill")

    card <- mod_trip_card_server("card", estado, dark)
    sens <- mod_sensitivity_server("sensitivity", estado, reset)

    # --- flags ---------------------------------------------------------------
    flag <- function(name, fn) {
      output[[name]] <- reactive(fn())
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag("idle_on", function() {
      s <- st()
      is.null(s) || !identical(estado$status, "in_progress")
    })
    flag("ready_on", function() {
      identical(estado$status, "in_progress") && !is.null(card$trip())
    })

    output$idle <- renderText({
      if (identical(estado$status, "finished")) label_trips_finished
      else if (identical(estado$status, "setup")) label_trips_idle
      else if (is.null(st())) label_no_day
      else label_no_trip
    })

    # --- end of shift (section 3) -------------------------------------------
    # /finish is the only place that computes outcome and user_percentile
    # (4.6 -- "siempre en el servidor"), so the UI has to call it when the
    # clock runs out; nothing else flips the day to finished.
    # The guard is finish_can_invoke() (utils.R): bounded retries, quiet once
    # the call has failed for good, and never before the resync has answered
    # -- the load test lost days to a /finish that timed out, was still
    # stored, and then found nothing on screen but an empty Trips tab.
    finish_task <- ExtendedTask$new(function(ctx, id) {
      api_async("api_finish", ctx, id)
    })
    finish_attempts <- reactiveVal(0L)
    observe({
      s <- st()
      req(identical(estado$status, "in_progress"), shift_over(s))
      req(finish_can_invoke(finish_task$status(), finish_attempts(),
                            isTRUE(estado$resync)))
      finish_attempts(finish_attempts() + 1L)
      finish_task$invoke(estado_ctx(estado), estado$experiment_id)
    })
    observe({
      res <- task_result(finish_task)
      if (!is.null(res)) {
        estado_set_finished(estado, res)
        return()
      }
      # NULL: the API said no or said nothing. Arm the resync (app.R polls
      # GET /state while it is set): a timed-out /finish landed server side,
      # and /state carries `result` for a finished day, so one GET ends the
      # day without posting again -- a second POST would only find 409.
      if (finish_task$status() %in% c("success", "error")) {
        estado$resync <- TRUE
      }
    })

    # --- sidebar KPIs --------------------------------------------------------
    output$current_time <- renderText({ s <- st(); s$clock %||% "" })
    output$earnings <- renderText({
      s <- st()
      if (is.null(s) || length(s$history) == 0) return("$0.00")
      h <- history_df(s$history)
      sprintf("$%.2f", h$user[length(h$user)])
    })
    output$decisions <- renderText({
      s <- st()
      if (is.null(s)) return("0")
      as.character(max(0, length(s$history) - 1))
    })

    # --- pending time bar (6.5) ---------------------------------------------
    # The hours are content (renderText); the width and the colour level are a
    # DOM concern, so shinyjs updates them -- section 6.1.1 allows it and forbids
    # renderUI instead.
    pending <- reactive({
      s <- st()
      if (is.null(s)) return(NULL)
      h <- as.numeric(s$pending_hours %||% 0)
      list(hours = h,
           pct = max(0, min(100, 100 * h / 8)),
           level = if (h > 4) "pending-ok" else if (h > 2) "pending-warn"
                   else "pending-low")
    })

    output$pending_hours <- renderText({
      p <- pending()
      if (is.null(p)) return("")
      sprintf("%.1f hours", p$hours)
    })

    observe({
      p <- pending()
      if (is.null(p)) return(invisible(NULL))
      shinyjs::runjs(sprintf(
        "var e=document.getElementById('%s'); if(e){e.style.width='%s'; e.className='pending-fill %s';}",
        fill_id, sprintf("%.0f%%", p$pct), p$level
      ))
    })

    # --- resume code and keyboard help --------------------------------------
    observeEvent(input$resume, {
      req(estado$resume_code)
      showModal(modalDialog(
        title = modal_resume_title,
        div(class = "mb-3",
          tags$label(class = "form-label", label_resume_code_copy),
          tags$code(class = "d-block fs-5 user-select-all",
                    style = "word-break: break-all;", estado$resume_code)),
        easyClose = TRUE,
        footer = modalButton(btn_close)
      ))
    })

    observeEvent(input$help, {
      showModal(modalDialog(
        title = kbd_title,
        tags$ul(
          tags$li(icon("arrow-right"), " ", kbd_arrow_right),
          tags$li(icon("arrow-left"),  " ", kbd_arrow_left),
          tags$li(tags$code("Enter"), " ", kbd_enter),
          tags$li(tags$code("?"),     " ", kbd_question),
          tags$li(tags$code("Esc"),   " ", kbd_escape)
        ),
        p(class = "text-muted mb-0", kbd_note),
        easyClose = TRUE,
        footer = modalButton(btn_close)
      ))
    })

    # Escape: Shiny binds it to the modal element, which only sees the event
    # when the focus is inside it. www/js/shortcuts.js reports the key here and
    # the server -- which owns the modal -- removes it, so Esc works no matter
    # which dialog (this one or the resume-code one) is open.
    observeEvent(input$escape_dismiss, removeModal(), ignoreInit = TRUE)

    # --- keyboard shortcuts: tell the client which ids to drive ---------------
    # The handler lives in www/js/shortcuts.js; it only ever clicks these
    # buttons, so a keypress goes through exactly the same path as a click.
    session$onFlushed(function() {
      session$sendCustomMessage("taxi.shortcuts", list(
        accept = card$accept_id,
        reject = card$reject_id,
        help   = session$ns("help"),
        escape = session$ns("escape_dismiss")
      ))
    }, once = TRUE)

    list(finished = reactive(identical(estado$status, "finished")))
  })
}
