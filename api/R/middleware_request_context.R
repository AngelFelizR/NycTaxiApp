# Structured request log (section 11): one JSON line per request carrying
# method, path, status, duration_ms, correlation_id and ip_hash.
#
# Three of those are only knowable when the request arrives, so they are
# attached to the request here and read back by `access_logger` once the
# response is known.
#
# This shares the header router's single catch-all with authentication on
# purpose: plumber2 aborts if the header router is materialised twice, so auth
# and the context have to travel together. Attaching is wrapped -- a logging
# failure must never turn into an authentication failure.

# No idempotency guard: plumber2 reuses the Request object across requests, so
# a guard would replay the previous request's correlation_id (observed: three
# consecutive lines with the same id) and could read method/path before they
# are populated. Attaching afresh every time is cheap and always correct.
attach_request_context <- function(request) {
  started <- Sys.time()
  # Captured here rather than at log time: this is the moment the router has
  # matched the path, and the logger's copy of the object may lag behind.
  request$log_method <- toupper(request$method %||% "")
  request$log_path <- paste0(request$path %||% "",
                             request$querystring %||% "")
  hdr <- request$get_header("x-request-id")
  request$correlation_id <-
    if (is.character(hdr) && length(hdr) == 1L && nzchar(hdr)) {
      trimws(hdr)
    } else {
      # Derivable from the clock rather than random(). Formatted, not
      # arithmetic: as.numeric(Sys.time()) * 1e6 exceeds the 15 significant
      # digits a double carries, so the microseconds round away and two
      # consecutive requests collided on the same id.
      paste0("r", gsub("[^0-9]", "", format(started, "%H%M%OS6")))
    }
  # Never an address: 4.3 stores and logs only the salted hash.
  request$ip_hash <- client_ip_hash(request)
  # Where the request began; the logger closes the measurement.
  request$log_start <- started
  invisible(request)
}

request_context <- function(request, response) {
  # Both halves must run: attach for the log, then the auth decision verbatim.
  tryCatch(attach_request_context(request),
           error = function(e) {
             cat("request_context: ", conditionMessage(e), "\n",
                 file = stderr())
           })
  internal_auth_header(request, response)
}

# Section 11: one JSON line per request -- method, path, status, duration_ms,
# correlation_id, ip_hash -- and no clear IP anywhere in it.
#
# The line is built here rather than in plumber2's `access_log_format`. That
# format is a cli/glue template: it substitutes `{...}` and then runs the
# RESULT through cli again, so any value containing a brace -- which every
# JSON object does -- is parsed as an R expression and takes the server down
# with "Could not parse cli `{}` expression" on the first request. Measured:
# three different formats, three crashes.
#
# Instead the logger receives the response (`res` in `...`) and the request,
# so the whole line can be sprintf'd in R where braces are just characters.
# Events other than "request" keep plumber2's console logger so conditions and
# warnings are not lost.
access_log_format <- "STATUS={response$status}"

status_from_access_log <- function(message) {
  m <- regmatches(as.character(message),
                  regexpr("STATUS=[0-9]+", as.character(message)))
  if (length(m) == 1L && nzchar(m)) {
    as.integer(sub("STATUS=", "", m))
  } else {
    200L
  }
}

access_logger <- function(event, message, request = NULL, time = Sys.time(),
                          ...) {
  if (!identical(event, "request") || is.null(request)) {
    plumber2::logger_console()(event, message, request, time, ...)
    return(invisible(NULL))
  }
  line <- list(
    method = request$log_method %||% "",
    path = request$log_path %||% "",
    # The only place the FINAL status reliably lives is plumber2's own
    # access-log evaluation: `res` in `...` and `request$response` were both
    # observed to lag behind (a 404 logged as 200, and a stale 404 on a 200).
    # The template below carries nothing but the number, so no brace is ever
    # substituted into it and cli cannot choke on it.
    status = status_from_access_log(message),
    duration_ms = if (is.null(request$log_start)) NA_integer_ else
      as.integer(round((as.numeric(Sys.time()) -
                        as.numeric(request$log_start)) * 1000)),
    correlation_id = request$correlation_id %||% "",
    ip_hash = request$ip_hash %||% ""
  )
  # na = "null": toJSON's default renders NA as the *string* "NA"
  # ({\"duration_ms\":\"NA\"}), so a consumer reading the type of a number
  # would get a string exactly when the request had no measurable duration --
  # which is the one case where the field cannot be trusted anyway.
  cat(as.character(jsonlite::toJSON(line, auto_unbox = TRUE, na = "null")),
      "\n", sep = "", file = stderr())
  invisible(NULL)
}
