# Shared helpers for the API (section 5.1): error responses, JSON body
# parsing, validation predicates and the JSON serializer used by every route.

`%||%` <- function(x, y) if (is.null(x)) y else x

# The dev container exports no TZ, so R reads the session zone as "" and
# RPostgres' own validation of its `timezone` argument fails ("Invalid time
# zone 'UTC' ... CCTZ: Unrecognized timezone of the input vector: ''"),
# leaving the connection's timezone slots empty: timestamps would then be
# bound and fetched through an empty zone. Every timestamp in the contract is
# UTC, so the session is pinned here -- before any connection is opened --
# for both entry points (plumber.R and the tests).
Sys.setenv(TZ = "UTC")

# Serializers must be passed to EVERY route (plumber2 0.1.0 has no global
# default; a route without one fails the Accept negotiation with 406).
json_serializers <- function() {
  list("application/json" = plumber2::format_unboxed())
}

# Set an RFC-shaped {error, message} body (contract components.schemas.Error)
# with the given status and stop route processing.
api_error <- function(response, status, error, message) {
  response$status <- as.integer(status)
  response$body <- list(error = error, message = message)
  plumber2::Break
}

# Load KEY=VALUE pairs from the repo .env without overriding variables that
# are already set (Docker injects them in production).
load_dotenv <- function(path) {
  if (!file.exists(path)) return(invisible(FALSE))
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines) & !startsWith(lines, "#")]
  for (line in lines) {
    if (!grepl("=", line, fixed = TRUE)) next
    key <- trimws(sub("=.*$", "", line))
    value <- trimws(sub("^[^=]*=", "", line))
    if (nzchar(key) && !nzchar(Sys.getenv(key))) {
      do.call(Sys.setenv, setNames(list(value), key))
    }
  }
  invisible(TRUE)
}

iso_utc <- function(x) {
  format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

week_day_names <- function() {
  c("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
}

# ---- request body -----------------------------------------------------------

# plumber2 only reads (and parses) the body when the handler declares a
# `body` formal, so the POST handlers take `body` as a raw vector. The json
# parser is identity: payloads are decoded manually below so malformed JSON
# gets the contract's 400 instead of reqres' auto 400/415 problem shape.
# "*/*" keeps other content types reaching the handler for the same 400.
raw_json_parsers <- function() {
  list(
    "application/json" = function(raw, directives) raw,
    "*/*" = function(raw, directives) raw
  )
}

# A sentinel for validation failures produced before a handler can run.
api_fail <- function(status, error, message) {
  structure(
    list(status = as.integer(status), error = error, message = message),
    class = "api_fail"
  )
}

is_api_fail <- function(x) inherits(x, "api_fail")

# Decode the raw request body as a JSON object.
read_json_body <- function(body, request) {
  content_type <- request$get_header("content-type") %||% ""
  content_type <- tolower(trimws(strsplit(content_type, ";", fixed = TRUE)[[1]][1]))
  if (!identical(content_type, "application/json")) {
    return(api_fail(400L, "bad_request", "Content-Type must be application/json."))
  }
  if (is.null(body) || length(body) == 0) {
    return(api_fail(400L, "bad_request", "Request body is required."))
  }
  text <- tryCatch(rawToChar(body), error = function(e) NULL)
  parsed <- if (is.null(text)) {
    NULL
  } else {
    tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE), error = function(e) NULL)
  }
  # The top level has to be a JSON object. `{}` parses to an unnamed list and
  # is a valid payload (it means "every optional field omitted"), while
  # arrays, scalars and broken JSON are not.
  if (is.null(text) || !startsWith(trimws(text), "{") || !is.list(parsed)) {
    return(api_fail(400L, "bad_request", "The request payload is invalid."))
  }
  parsed
}

# ---- validation -------------------------------------------------------------

missing_fields <- function(payload, fields) {
  fields[vapply(fields, function(f) is.null(payload[[f]]), logical(1))]
}

is_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x)

is_number <- function(x) is.numeric(x) && length(x) == 1L && !is.na(x) && is.finite(x)

is_wholenumber <- function(x) is_number(x) && x == round(x)

is_zone_id <- function(x) is_wholenumber(x) && x >= 1 && x <= 265

# Simple address check (regex + length, no MX lookup) shared by Setup,
# share-email and the waitlist.
EMAIL_PATTERN <- "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"

is_email <- function(x, max_chars = 254L) {
  is_string(x) && nchar(x) <= max_chars && grepl(EMAIL_PATTERN, x)
}

valid_company <- function(x) is_string(x) && x %in% c("Lyft", "Uber")

company_to_hvfhs <- function(company) {
  if (identical(company, "Uber")) "HV0003" else "HV0005"
}
