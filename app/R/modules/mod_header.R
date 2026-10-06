# Navbar header (6.3): app identity plus the state of the session's day.
# Phase 5 will add the live clock and the pending-time bar here.

mod_header_ui <- function(id) {
  ns <- NS(id)
  div(class = "taxi-header d-flex align-items-center gap-3",
    span(class = "fs-6 fw-semibold", app_title),
    span(class = "badge rounded-pill text-bg-secondary",
         textOutput(ns("status"), inline = TRUE))
  )
}

mod_header_server <- function(id, estado) {
  moduleServer(id, function(input, output, session) {
    output$status <- renderText({
      switch(estado$status %||% "none",
             "setup" = status_setup,
             "in_progress" = status_in_progress,
             "finished" = status_finished,
             "abandoned" = status_abandoned,
             status_none)
    })
  })
}
