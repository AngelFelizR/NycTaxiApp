# Steps 1 + 2: initial conditions + validation (decided by the API) -------------
# No renderUI, no shinyjs. Visibility = conditionalPanel() on boolean outputs.
# API calls run in mirai daemons via ExtendedTask; buttons show a busy state.

mod_setup_ui <- function(id) {
  ns <- NS(id)
  tagList(
    intro_text(),
    card(plotOutput(ns("plot_intro"), height = 140)),
    p("Define the initial conditions that will keep constant during the whole ",
      "8 hours of a working day."),

    div(class = "field",
      selectInput(ns("company"), "Taxi Company", choices = character(0)),
      conditionalPanel("output.company_hint_on", ns = ns,
        div(class = "warn-msg", textOutput(ns("company_hint"))))
    ),
    div(class = "field",
      textInput(ns("start_dt"), "Initial Date-time", value = ""),
      conditionalPanel("output.datetime_hint_on", ns = ns,
        div(class = "warn-msg", textOutput(ns("datetime_hint"))))
    ),
    selectInput(ns("start_zone"), "Initial Location", choices = character(0)),
    leafletOutput(ns("map_start"), height = 220),

    conditionalPanel("output.is_optimal", ns = ns,
      div(class = "text-center text-success my-2",
          h4(icon("check"), " ", textOutput(ns("perfect_msg"), inline = TRUE)))),

    div(class = "text-center my-3",
      conditionalPanel("!output.validated", ns = ns,
        input_task_button(ns("validate"), "Validate Starting Conditions",
                          label_busy = "Validating...")),
      conditionalPanel("output.validated", ns = ns,
        input_task_button(ns("start_day"), "Start The Day",
                          label_busy = "Starting..."))
    )
  )
}

mod_setup_server <- function(id, opts, reset) {
  moduleServer(id, function(input, output, session) {
    validation <- reactiveVal(NULL)   # last /validate response
    day        <- reactiveVal(NULL)   # /days response once the day starts

    # Selector choices and defaults come from the API
    observeEvent(opts(), {
      o <- opts()
      updateSelectInput(session, "company",    choices = o$companies, selected = o$companies[1])
      updateTextInput(session,   "start_dt",   value   = o$default_start_dt)
      updateSelectInput(session, "start_zone", choices = o$zones)
    })

    # --- async tasks ---------------------------------------------------------
    validate_task <- ExtendedTask$new(function(company, start_dt, start_zone) {
      api_async("api_validate", company, start_dt, start_zone)
    })
    create_task <- ExtendedTask$new(function(company, start_dt, start_zone) {
      api_async("api_create_day", company, start_dt, start_zone)
    })
    bind_task_button(validate_task, "validate")
    bind_task_button(create_task,   "start_day")

    observeEvent(input$validate,
      validate_task$invoke(input$company, input$start_dt, input$start_zone))
    observeEvent(input$start_day,
      create_task$invoke(input$company, input$start_dt, input$start_zone))

    observe({
      res <- task_result(validate_task)
      if (!is.null(res)) validation(res)
    })
    observe({
      res <- task_result(create_task)
      if (!is.null(res)) day(res)
    })

    # Editing any condition invalidates the previous validation
    observeEvent(list(input$company, input$start_dt, input$start_zone),
                 validation(NULL), ignoreInit = TRUE)
    observeEvent(reset(), { validation(NULL); day(NULL) }, ignoreInit = TRUE)

    # Boolean flags consumed by the conditionalPanels
    flag <- function(name, fn) {
      output[[name]] <- reactive(fn())
      outputOptions(output, name, suspendWhenHidden = FALSE)
    }
    flag("validated",         function() !is.null(validation()))
    flag("is_optimal",        function() isTRUE(validation()$optimal))
    flag("company_hint_on",   function() has_hint(validation()$company_hint))
    flag("datetime_hint_on",  function() has_hint(validation()$datetime_hint))

    output$company_hint  <- renderText(validation()$company_hint)
    output$datetime_hint <- renderText(validation()$datetime_hint)
    output$perfect_msg   <- renderText(validation()$message)

    output$plot_intro <- renderPlot(line_plot(
      data.frame(step = 1:12, user = cumsum(c(5, 12, 9, 20, 14, 25, 18, 30, 22, 35, 28, 40))),
      "user"))
    output$map_start <- renderLeaflet(basemap())

    list(day = day)
  })
}
