# Steps 1 + 2: initial conditions + validation (decided by the API) -------------
# No renderUI for structure (6.1.1); visibility = conditionalPanel() on boolean
# outputs. API calls run in mirai daemons via ExtendedTask; the task buttons
# show a busy state while the call is in flight.
#
# The only dynamic structure is the confirm modal (6.5), which lives in
# mod_confirm_modal.R and is opened by app.R once the day exists.

mod_setup_ui <- function(id) {
  ns <- NS(id)
  opts <- app_options()
  tagList(
    intro_text(),
    p(setup_lead),

    layout_columns(
      col_widths = c(6, 6),
      div(class = "field",
        selectizeInput(ns("company"), label_company,
                       choices = opts$companies, selected = opts$companies[1]),
        conditionalPanel("output.company_hint_on", ns = ns,
          div(class = "warn-msg", textOutput(ns("company_hint"))))
      ),
      div(class = "field",
        textInput(ns("start_dt"), label_start_datetime,
                  value = opts$default_start_dt),
        conditionalPanel("output.datetime_hint_on", ns = ns,
          div(class = "warn-msg", textOutput(ns("datetime_hint"))))
      )
    ),

    div(class = "field",
      selectizeInput(ns("start_zone"), label_start_zone,
                     choices = opts$zones, selected = opts$default_location_id,
                     options = list(placeholder = "Search a TLC zone")),
      conditionalPanel("output.zone_missing", ns = ns,
        div(class = "warn-msg", textOutput(ns("zone_msg"))))
    ),
    leafletOutput(ns("map_start"), height = 240),

    conditionalPanel("output.is_optimal", ns = ns,
      div(class = "text-center text-success my-2",
        h4(icon("check"), " ", textOutput(ns("perfect_msg"), inline = TRUE)))),

    conditionalPanel("output.preparing_on", ns = ns,
      div(class = "text-center text-muted my-2",
        textOutput(ns("preparing"), inline = TRUE))),

    div(class = "field mt-3",
      checkboxInput(ns("advanced"), label_seed_section, FALSE),
      conditionalPanel("output.advanced_on", ns = ns,
        div(class = "d-flex align-items-end gap-2",
          div(class = "flex-grow-1",
            textInput(ns("seed"), label_seed, value = "")),
          actionButton(ns("seed_info"), "", icon = icon("circle-question"),
                       class = "btn-outline-secondary mb-1")
        ))
    ),

    div(class = "field mt-3",
      textInput(ns("email"), label_email, value = ""),
      conditionalPanel("output.email_bad", ns = ns,
        div(class = "warn-msg", textOutput(ns("email_msg")))),
      checkboxInput(ns("card"), label_result_card, FALSE),
      checkboxInput(ns("marketing"), label_marketing, FALSE),
      tags$a(label_privacy, href = "privacy.html", target = "_blank",
             rel = "noopener")
    ),

    div(class = "text-center my-3",
      conditionalPanel("!output.validated", ns = ns,
        input_task_button(ns("validate"), btn_validate,
                          label_busy = btn_validating)),
      conditionalPanel("output.validated", ns = ns,
        input_task_button(ns("start_day"), btn_start,
                          label_busy = btn_starting))
    )
  )
}

mod_setup_server <- function(id, estado, reset) {
  moduleServer(id, function(input, output, session) {
    validation <- reactiveVal(NULL)   # last /validate-trip-start response
    day        <- reactiveVal(NULL)   # CreatedExperiment once the day exists

    # --- async tasks ---------------------------------------------------------
    validate_task <- ExtendedTask$new(function(ctx, company, start_dt, zone) {
      api_async("api_validate_trip_start", ctx, company, start_dt, zone)
    })
    create_task <- ExtendedTask$new(
      function(ctx, company, start_dt, zone, seed, email, marketing) {
        api_async("api_create_experiment", ctx, company, start_dt, zone,
                  seed, email, marketing)
      })
    bind_task_button(validate_task, "validate")
    bind_task_button(create_task,   "start_day")

    observeEvent(input$validate, {
      req(input$company, input$start_dt, input$start_zone)
      validate_task$invoke(estado_ctx(estado), input$company,
                           input$start_dt, input$start_zone)
    })

    observeEvent(input$start_day, {
      req(input$company, input$start_dt, input$start_zone, email_ok())
      create_task$invoke(
        estado_ctx(estado), input$company, input$start_dt, input$start_zone,
        seed = trimws(input$seed), email = trimws(input$email),
        marketing = input$marketing
      )
    })

    observe({
      res <- task_result(validate_task)
      if (!is.null(res)) validation(res)
    })
    observe({
      res <- task_result(create_task)
      if (!is.null(res)) {
        estado_set_created(estado, res)
        # The API never echoes the address back (PII, 9.1), but Results needs
        # to know whether the second email prompt is pointless (6.5).
        estado$email <- trimws(input$email %||% "")
        day(res)
        # The R6 method has no default for mode; "replace" keeps the back
        # button from walking through every condition the player edited.
        session$updateQueryString(paste0("?exp=", res$experiment_id),
                                  mode = "replace")
      }
    })

    # Editing any condition invalidates the previous validation.
    observeEvent(list(input$company, input$start_dt, input$start_zone),
                 validation(NULL), ignoreInit = TRUE)
    observeEvent(reset(), {
      validation(NULL)
      day(NULL)
      updateTextInput(session, "seed", value = "")
    }, ignoreInit = TRUE)

    # --- derived flags / hints ---------------------------------------------
    hints <- reactive(validation_hints(validation(), input$company,
                                       input$start_dt))

    email_ok <- reactive({
      e <- trimws(input$email %||% "")
      !nzchar(e) || grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]{2,}$", e)
    })

    flag <- function(name, fn) {
      output[[name]] <- reactive(fn())
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag("validated",        function() !is.null(validation()))
    flag("is_optimal",       function() isTRUE(validation()$is_optimal))
    flag("company_hint_on",  function() nzchar(hints()$company_hint))
    flag("datetime_hint_on", function() nzchar(hints()$datetime_hint))
    flag("advanced_on",      function() isTRUE(input$advanced))
    flag("email_bad",        function() !email_ok())
    flag("zone_missing",     function() !nzchar(input$start_zone %||% ""))
    flag("preparing_on",     function() identical(estado$status, "setup"))

    output$company_hint  <- renderText(hints()$company_hint)
    output$datetime_hint <- renderText(hints()$datetime_hint)
    output$perfect_msg   <- renderText(hints()$message)
    output$zone_msg      <- renderText(err_zone_required)
    output$email_msg     <- renderText(err_email)
    output$preparing     <- renderText({
      sprintf("%s (%d%%)", label_progress, estado$progress %||% 0L)
    })

    observeEvent(input$seed_info, {
      showModal(modalDialog(
        title = label_seed_section,
        p(seed_help),
        easyClose = TRUE,
        footer = modalButton(btn_close)
      ))
    })

    # --- bidirectional Leaflet (6.5) ----------------------------------------
    output$map_start <- renderLeaflet({
      z <- zones_map_data()
      m <- basemap()
      if (is.null(z)) return(m)
      addPolygons(m, data = z, layerId = ~LocationID,
                  weight = 1, color = "#e3e6ea",
                  fillColor = "#ffffff", fillOpacity = 0.55,
                  highlightOptions = highlightOptions(
                    weight = 2, color = brand_colour(), bringToFront = TRUE))
    })

    # Clicking a zone on the map selects it (shape click carries the layer id).
    observeEvent(input$map_start_shape_click, {
      updateSelectizeInput(session, "start_zone",
                           selected = as.character(input$map_start_shape_click$id))
    }, ignoreInit = TRUE)

    # Selecting a zone highlights it and recenters the map.
    observeEvent(input$start_zone, {
      z <- zones_map_data()
      req(z, input$start_zone)
      sel <- z[as.character(z$LocationID) == as.character(input$start_zone), ]
      proxy <- leafletProxy("map_start", session) |> clearGroup("selected")
      if (nrow(sel) == 0) return(invisible(NULL))
      bb <- sf::st_bbox(sel)
      proxy |>
        addPolygons(data = sel, group = "selected",
                    color = brand_colour(), weight = 3,
                    fillColor = brand_colour(), fillOpacity = 0.25) |>
        setView(lng = (bb["xmin"] + bb["xmax"]) / 2,
                lat = (bb["ymin"] + bb["ymax"]) / 2, zoom = 11)
    }, ignoreInit = TRUE)

    list(day = day)
  })
}
