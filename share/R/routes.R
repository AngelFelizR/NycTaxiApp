# Route handlers and the api() object for the share service (5.10, 7.x).
# Kept out of plumber.R so tests can build the app, hit it with httr2, and
# never call api_run().

# Nginx/Cloudflare put the visitor address here; the API's per-IP limits (5.4)
# need it, and an empty one degrades to the "unknown" bucket.
client_ip_of <- function(request) {
  for (h in c("cf-connecting-ip", "x-client-ip", "x-real-ip")) {
    v <- request$get_header(h)
    if (!is.null(v) && nzchar(v)) return(trimws(v))
  }
  ""
}

# ShareToken is base64url, 12 characters (contract/share.openapi.yaml).
valid_token <- function(token) {
  is.character(token) && length(token) == 1L && grepl("^[A-Za-z0-9_-]{12}$", token)
}

valid_email <- function(email) {
  e <- trimws(as.character(email %||% "")[1])
  !is.na(e) && nzchar(e) && nchar(e) < 254 &&
    grepl("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]{2,}$", e)
}

# Both share routes read the same aggregate. A non-200 (unknown token, day not
# finished, API down) is surfaced so each handler can pick its own status.
fetch_data <- function(request, token) {
  api_share_data(api_ctx(client_ip_of(request)), token)
}

# plumber2's @serializer png is a *graphics* serializer: it opens a device,
# captures whatever is drawn and DISCARDS response$body. The card is already
# bytes (share_png()), so the formatter here is a pass-through.
respond_png <- function(response) {
  response$set_formatter("image/png" = function(x) x, default = "image/png")
}

respond_html <- function(response) {
  response$set_formatter("text/html" = reqres::format_plain(),
                         default = "text/html")
}

# The two upstream answers the page is willing to render: 404 means nobody
# owns this token, anything else means the card is temporarily unavailable.
abort_body <- function(status) {
  list(status = status,
       body = list(error = if (status == 404L) "not_found" else "service_unavailable",
                   message = if (status == 404L) "Not found."
                             else "The result is not available right now."))
}

bad_request <- function(response, error, message) {
  response$status <- 422L
  response$body <- list(error = error, message = message)
  plumber2::Break
}

# The one route on this service that is NOT public (ADR-005). The API is on
# nyctaxi_api_net like everything else here, so the key is what keeps a
# neighbour -- a Shiny container, say -- from asking us to render arbitrary
# payloads. Compared with plain `identical` rather than a constant-time digest
# the way the API does it: this is a 44-character random key on a private
# network whose port is never published, not an endpoint behind the edge.
internal_key_ok <- function(request) {
  expected <- Sys.getenv("API_INTERNAL_KEY")
  provided <- request$get_header("x-internal-key")
  nzchar(expected) && is.character(provided) && length(provided) == 1L &&
    nzchar(provided) && identical(expected, provided)
}

# ---- POST /render-card (internal, ADR-005) --------------------------------
# The API pushes the card payload because plumber2 serves one request at a
# time: if we pulled GET /share-data/{token} here we would be calling back
# into the very handler that is waiting for us. The payload is the same
# document GET /share-data returns, so it inherits 5.7: no experiment_id, no
# email, no IP.
render_card_handler <- function(request, response, body) {
  if (!internal_key_ok(request)) {
    response$status <- 403L
    response$body <- list(error = "forbidden",
                          message = "Invalid or missing X-Internal-Key header.")
    return(plumber2::Break)
  }

  payload <- tryCatch(
    jsonlite::fromJSON(rawToChar(body), simplifyVector = TRUE),
    error = function(e) NULL
  )
  if (!is.list(payload) || is.null(payload$day_label) ||
      is.null(payload$history)) {
    response$status <- 422L
    response$body <- list(
      error = "unprocessable_entity",
      message = "Expected a share payload: day_label and history."
    )
    return(plumber2::Break)
  }

  bytes <- tryCatch(share_png(payload), error = function(e) {
    cat("render-card: ", conditionMessage(e), "\n", file = stderr())
    NULL
  })
  if (is.null(bytes)) {
    response$status <- 500L
    response$body <- list(error = "internal_error",
                          message = "Could not render the card.")
    return(plumber2::Break)
  }

  respond_png(response)
  # Not a public resource: there is no URL to cache, only this exchange.
  response$set_header("Cache-Control", "no-store")
  response$body <- bytes
  plumber2::Break
}

# ---- GET /share/{token}.png ------------------------------------------------
# 7.1: cached in Redis for 24h, never on disk, served with the long
# Cache-Control so Cloudflare and the crawlers never re-render it.
png_handler <- function(request, response, token) {
  if (!valid_token(token)) return(abort_with(response, 404L))
  cached <- png_cache_get(token)
  if (!is.null(cached)) {
    respond_png(response)
    response$set_header("Cache-Control", "public, max-age=86400, s-maxage=604800")
    response$body <- cached
    return(plumber2::Break)
  }
  got <- fetch_data(request, token)
  if (got$status != 200L || is.null(got$data)) {
    return(abort_with(response, if (got$status %in% c(404L, 403L)) 404L else 503L))
  }
  bytes <- share_png(got$data)
  png_cache_put(token, bytes)
  respond_png(response)
  response$set_header("Cache-Control", "public, max-age=86400, s-maxage=604800")
  response$body <- bytes
  plumber2::Break
}

# ---- GET /share/{token} ----------------------------------------------------
# 7.2: never cached at the edge, so the view counter can see the hit.
html_handler <- function(request, response, token) {
  if (!valid_token(token)) return(abort_with(response, 404L))
  got <- fetch_data(request, token)
  if (got$status != 200L || is.null(got$data)) {
    return(abort_with(response, if (got$status %in% c(404L, 403L)) 404L else 503L))
  }
  # 7.4: a crawler that only renders the card is not a visit.
  if (!is_bot(request$get_header("user-agent"))) views_incr(token)
  respond_html(response)
  response$set_header("Cache-Control", "no-store")
  response$body <- share_page(got$data, token)
  plumber2::Break
}

abort_with <- function(response, status) {
  b <- abort_body(status)
  response$status <- b$status
  response$body <- b$body
  plumber2::Break
}

# ---- POST /waitlist --------------------------------------------------------
# The per-IP limit (5/day) lives on the API (5.4); a 429 is relayed as-is.
waitlist_handler <- function(request, response, body) {
  payload <- tryCatch(
    jsonlite::fromJSON(rawToChar(body), simplifyVector = FALSE),
    error = function(e) NULL
  )
  email <- if (is.list(payload)) payload$email %||% NULL else NULL
  if (!valid_email(email)) {
    return(bad_request(response, "unprocessable_entity",
                       "Enter a valid email address."))
  }
  res <- api_waitlist(api_ctx(client_ip_of(request)), trimws(as.character(email)))
  if (res$status %in% c(429L, 503L)) {
    response$status <- res$status
    response$body <- list(
      error = if (res$status == 429L) "rate_limit_exceeded" else "service_unavailable",
      message = if (nzchar(res$message)) res$message else "Please try again later."
    )
    return(plumber2::Break)
  }
  if (res$status != 200L) {
    response$status <- res$status
    response$body <- list(error = "upstream_error", message = "Could not save your email.")
    return(plumber2::Break)
  }
  response$body <- list(message = if (nzchar(res$message)) {
    res$message
  } else {
    "You are on the waitlist. We will email you when a spot opens."
  })
  plumber2::Break
}

# ---- GET /health -----------------------------------------------------------
# Internal healthcheck only (5.10). Redis being down does not fail it: the
# card still renders without a cache (fail open).
health_handler <- function(request, response) {
  response$body <- list(status = "ok",
                        redis = if (is.null(redis_con())) "unavailable" else "ok")
  plumber2::Break
}

not_found_handler <- function(request, response) {
  abort_with(response, 404L)
}

# ---- wiring ----------------------------------------------------------------
share_api <- function(host = "0.0.0.0", port = 8020L) {
  # Every route declares JSON: it is what the contract wants for every error,
  # and the two success paths opt into their own type inside the handler
  # (see respond_png/respond_html). Letting the client negotiate would make
  # `Accept: */*` pick the image and hide the error document.
  json_fmt <- list("application/json" = plumber2::format_unboxed())
  raw_parsers <- list(
    "application/json" = function(raw, directives) raw,
    "*/*" = function(raw, directives) raw
  )

  api <- plumber2::api(host = host, port = port)
  api <- plumber2::api_get(api, "/health", health_handler, serializers = json_fmt)
  # The .png route is registered before its parent: `<token>` would otherwise
  # swallow "abc123.png" and the HTML handler would 404 it.
  api <- plumber2::api_get(api, "/share/<token>.png", png_handler, serializers = json_fmt)
  api <- plumber2::api_get(api, "/share/<token>", html_handler, serializers = json_fmt)
  # Internal: never reachable from the Internet, because Nginx proxies only
  # /share/ and /waitlist and this port is expose:, not ports:.
  api <- plumber2::api_post(api, "/render-card", render_card_handler,
                            serializers = json_fmt, parsers = raw_parsers)
  api <- plumber2::api_post(api, "/waitlist", waitlist_handler,
                            serializers = json_fmt, parsers = raw_parsers)
  plumber2::api_any(api, "/*", not_found_handler, serializers = json_fmt)
}
