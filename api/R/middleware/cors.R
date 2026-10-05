# CORS (section 5.7): defense in depth only -- the API never receives browser
# traffic. A single allowed origin per environment; `Origin: null` and any
# other origin get `access-control-allow-origin: false` (rejected by
# browsers), so no CORS headers are ever echoed back for them.

cors_origin <- function() {
  if (identical(Sys.getenv("ENV"), "production")) {
    "https://nyctaxiapp.angelfeliz.com"
  } else {
    "http://localhost:3838"
  }
}

apply_cors <- function(api) {
  api <- plumber2::api_security_cors(
    api,
    path = "/*",
    origin = cors_origin(),
    allowed_headers = c("Content-Type", "X-Internal-Key", "X-Client-IP", "X-Resume-Code", "X-Device")
  )
  # firesafety inserts its cors_main route FIRST and its handler returns
  # FALSE whenever the request has no usable Origin header; in routr a FALSE
  # route result stops the whole chain, so server-to-server calls (no Origin)
  # would never reach an endpoint, and its origin lookup errors with
  # "argument is of length zero" when the header is absent. Replace the
  # handler with an equivalent one that always continues the chain.
  route <- api$plugins$request_routr$get_route("cors_main")
  priv <- route$.__enclos_env__$private
  origin <- cors_origin()
  priv$handlerMap$all$`/*`$handler <- function(request, response, ...) {
    o <- request$get_header("origin")
    allowed <- is.character(o) && length(o) == 1L && identical(tolower(o), origin)
    response$set_header(
      "access-control-allow-origin",
      if (allowed) o else "false"
    )
    response$append_header("vary", "origin")
    TRUE
  }
  priv$update_regexes()
  api
}
