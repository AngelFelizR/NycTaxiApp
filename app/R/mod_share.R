# Share buttons and the second email prompt (6.5, 7.3, 7.4).
#
# Everything here is static markup: section 6.1.1 forbids renderUI for
# structure, so the three anchors are built in the UI with `href="#"` and the
# server points them at the card the moment the day carries a share_token
# (the same trick Results already uses for the vs-policy colour). Anchors --
# not actionButtons -- on purpose: a real `<a>` keeps the browser's user
# activation, so X and LinkedIn open a tab instead of being eaten by a popup
# blocker, and it stays middle-clickable and copyable.
#
# Each click also emits `event: share_click, channel: ...` on stderr (7.4).

# A JS string literal: toJSON quotes and escapes, so a token or a URL can never
# break out of the script it is pasted into.
js_str <- function(x) as.character(jsonlite::toJSON(as.character(x), auto_unbox = TRUE))

mod_share_ui <- function(id) {
  ns <- NS(id)
  div(class = "share-bar d-flex gap-2 justify-content-center flex-wrap mt-3",
    tags$a(id = ns("download"), class = "btn btn-outline-primary", href = "#",
           icon("download"), " ", label_share_download),
    actionButton(ns("copy"), label_share_copy, icon = icon("link"),
                 class = "btn-outline-secondary"),
    tags$a(id = ns("x"), class = "btn btn-outline-dark", href = "#",
           target = "_blank", rel = "noopener", label_share_x),
    tags$a(id = ns("linkedin"), class = "btn btn-outline-info", href = "#",
           target = "_blank", rel = "noopener", label_share_linkedin),
    actionButton(ns("email"), label_share_email, icon = icon("envelope"),
                 class = "btn-outline-secondary")
  )
}

mod_share_server <- function(id, estado) {
  moduleServer(id, function(input, output, session) {
    task <- ExtendedTask$new(function(ctx, exp_id, email) {
      api_async("api_share_email", ctx, exp_id, email)
    })

    card_url <- reactive(share_url(estado$share_token))

    # Point the three anchors at the card and report their channel (7.4). The
    # listener runs inside the click, so the browser still counts it as a user
    # gesture; `dataset.shareReady` makes a re-run a no-op.
    observe({
      url <- card_url()
      req(nzchar(url))
      ns <- session$ns
      shinyjs::runjs(sprintf(paste0(
        "(function(){",
        "  function bind(id, href, ch, download){",
        "    var e = document.getElementById(id);",
        "    if (!e || e.dataset.shareReady) return;",
        "    e.dataset.shareReady = '1'; e.href = href;",
        "    if (download) e.setAttribute('download', 'nyc-taxi-card.png');",
        "    e.addEventListener('click', function(){",
        "      if (window.Shiny) Shiny.setInputValue(%s, ch, {priority:'event'});",
        "    });",
        "  }",
        "  bind(%s, %s, %s, true);",
        "  bind(%s, %s, %s, false);",
        "  bind(%s, %s, %s, false);",
        "})();"),
        js_str(paste0(ns("channel"), "clicked")),
        js_str(ns("download")), js_str(paste0(url, ".png")), js_str("download"),
        js_str(ns("x")),
        js_str(paste0("https://twitter.com/intent/tweet?url=",
                      utils::URLencode(url, reserved = TRUE))),
        js_str("x"),
        js_str(ns("linkedin")),
        js_str(paste0("https://www.linkedin.com/sharing/share-offsite/?url=",
                      utils::URLencode(url, reserved = TRUE))),
        js_str("linkedin")
      ))
    })

    # One observer for the three anchors: the browser has already navigated by
    # the time this fires, so the job is only the structured log line.
    observeEvent(input$channelclicked, {
      log_event("share_click", channel = as.character(input$channelclicked))
    }, ignoreInit = TRUE)

    # --- copy link -----------------------------------------------------------
    observeEvent(input$copy, {
      log_event("share_click", channel = "copy")
      url <- card_url()
      req(nzchar(url))
      ok  <- sprintf("Shiny.setInputValue(%s, true, {priority:'event'});",
                     js_str(paste0(session$ns("copy_ok"), "1")))
      bad <- sprintf("Shiny.setInputValue(%s, false, {priority:'event'});",
                     js_str(paste0(session$ns("copy_ok"), "0")))
      shinyjs::runjs(sprintf(paste0(
        "(function(u){",
        "  if (navigator.clipboard && navigator.clipboard.writeText) {",
        "    navigator.clipboard.writeText(u).then(function(){%s}, function(){%s});",
        "  } else { %s }",
        "})(%s);"), ok, bad, bad, js_str(url)))
    })

    observeEvent(input$copy_ok1, {
      showNotification(msg_share_copied, type = "message", duration = 4)
    }, ignoreInit = TRUE)
    observeEvent(input$copy_ok0, {
      showNotification(msg_share_copy_failed, type = "warning", duration = 6)
    }, ignoreInit = TRUE)

    # --- email the card ------------------------------------------------------
    # Setup already told us whether the address exists (6.5): with one on file
    # the button sends immediately with no body (5.6); without one it asks.
    send_card <- function(email) {
      if (task$status() == "running") return()
      task$invoke(estado_ctx(estado), estado$experiment_id, email)
    }

    observeEvent(input$email, {
      log_event("share_click", channel = "email")
      req(estado$experiment_id)
      if (nzchar(trimws(as.character(estado$email %||% "")[1]))) {
        send_card(NULL)
      } else {
        showModal(modalDialog(
          title = label_share_email_title,
          p(class = "mb-2", label_share_email_help),
          textInput(session$ns("email_addr"), label_share_email, value = ""),
          p(class = "mb-0 small",
            tags$a(label_privacy, href = "privacy.html", target = "_blank",
                   rel = "noopener")),
          footer = tagList(
            actionButton(session$ns("send"), btn_share_email_send, type = "primary"),
            modalButton(btn_share_email_close)
          )
        ))
      }
    })

    observeEvent(input$send, {
      addr <- trimws(as.character(input$email_addr %||% "")[1])
      if (!grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]{2,}$", addr) ||
          nchar(addr) >= 254) {
        showNotification(err_share_email, type = "warning", duration = 5)
        return()
      }
      send_card(addr)
    })

    observe({
      res <- task_result(task)
      if (is.null(res)) return(invisible(NULL))
      removeModal()
      showNotification(msg_share_email_sent, type = "message", duration = 6)
    })

    list(card_url = card_url)
  })
}
