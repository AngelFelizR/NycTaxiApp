# Post-game feedback (6.5): rating 1-5, optional comment, optional public
# consent (off by default, never implying the email).
#
# Like mod_confirm_modal it owns a modal rather than a persistent uiOutput:
# the form only exists once the player asks for it. POST /experiments/{id}/
# feedback needs the resume code, which lives in estado.

mod_feedback_server <- function(id, estado, on_saved = function() NULL) {
  moduleServer(id, function(input, output, session) {
    task <- ExtendedTask$new(function(ctx, exp_id, rating, comment, public) {
      api_async("api_feedback", ctx, exp_id, rating, comment, public)
    })

    open <- function() {
      req(estado$experiment_id)
      showModal(modalDialog(
        title = label_feedback_title,
        div(class = "mb-3",
          radioButtons(session$ns("rating"), label_feedback_rating,
                       choices = seq_len(5), selected = NA, inline = TRUE)),
        textAreaInput(session$ns("comment"), label_feedback_comment,
                      rows = 3, width = "100%"),
        checkboxInput(session$ns("public"), label_feedback_public, FALSE),
        p(class = "text-muted small mb-0", label_feedback_public_help),
        footer = tagList(
          actionButton(session$ns("send"), btn_feedback_submit,
                       type = "primary"),
          modalButton(btn_feedback_close)
        )
      ))
    }

    observeEvent(input$send, {
      r <- suppressWarnings(as.integer(input$rating))
      if (length(r) != 1L || is.na(r) || r < 1L || r > 5L) {
        showNotification(err_feedback_rating, type = "warning", duration = 5)
        return()
      }
      # One in-flight request: the modal is not dismissed until the API answers.
      if (task$status() == "running") return()
      task$invoke(estado_ctx(estado), estado$experiment_id, r,
                  input$comment, input$public)
    })

    observe({
      res <- task_result(task)
      if (is.null(res)) return(invisible(NULL))
      removeModal()
      showNotification(msg_feedback_saved, type = "message", duration = 6)
      on_saved()
    })

    list(open = open)
  })
}
