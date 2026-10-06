# Mandatory confirmation modal after Start The Day (6.5): the one-time resume
# code is shown here, with a copy button, and the day only moves to Trips once
# the player has seen it.
#
# The whole UI is built inside open() rather than as a uiOutput: showModal()
# replaces whatever was rendered last, so there is nothing for a persistent
# output to hold, and this keeps mod_setup free of modal code.

mod_confirm_modal_server <- function(id, estado, on_continue) {
  moduleServer(id, function(input, output, session) {
    code <- reactive({
      code <- estado$resume_code
      if (is.null(code) || !nzchar(code)) return(NULL)
      code
    })

    open <- function() {
      req(code())
      showModal(modalDialog(
        title = modal_title,
        p(modal_lead),
        div(class = "mb-3",
          tags$label(class = "form-label", label_resume_code_copy),
          tags$code(class = "d-block fs-5 user-select-all",
                    style = "word-break: break-all;", code())
        ),
        footer = tagList(
          actionButton(session$ns("copy"), btn_copy,
                       class = "btn-outline-secondary"),
          actionButton(session$ns("continue"), btn_continue, type = "primary")
        )
      ))
    }

    # Copy the code (clipboard is a browser API; shinyjs runs it in the page).
    observeEvent(input$copy, {
      shinyjs::runjs(sprintf(
        "navigator.clipboard && navigator.clipboard.writeText(%s);",
        jsonlite::toJSON(estado$resume_code %||% "", auto_unbox = TRUE)
      ))
      updateActionButton(session, "copy", label = btn_copied)
    })

    observeEvent(input$continue, {
      removeModal()
      on_continue()
    })

    list(open = open)
  })
}
