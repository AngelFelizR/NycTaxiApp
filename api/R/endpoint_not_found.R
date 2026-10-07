# Catch-all: the contract only documents the four phase-1 routes; anything
# else is a 404 with the standard Error shape. plumber2 resets a 404 status
# to 200 as soon as ANY handler runs (including this catch-all), so the
# reliable signal for "no endpoint matched" is an unset response body: a
# matched route has already stored its body by the time the chain reaches
# here (it returns TRUE and lets the chain continue).

not_found_handler <- function(request, response) {
  if (nzchar(Sys.getenv("API_TRACE"))) {
    cat(sprintf(
      "not_found entered: is.null(body)=%s identical('', body)=%s status=%s\n",
      is.null(response$body),
      identical(response$body, ""),
      as.character(response$status)
    ), file = stderr())
  }
  b <- response$body
  if (is.null(b) || identical(b, "") ||
    (is.character(b) && length(b) == 1L && !nzchar(b))) {
    response$status <- 404L
    response$body <- list(error = "not_found", message = "No route matches.")
  }
  plumber2::Break
}
