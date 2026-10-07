# The share service's only client: httr2 against the private API. NO Shiny
# code here. Mirrors app/R/api_client.R but knows two routes instead of
# eighteen -- section 5.10 lists them as the whole contract this side needs.

api_ctx <- function(ip = "") {
  url <- Sys.getenv("TAXI_API_URL", "http://127.0.0.1:8000")
  if (!nzchar(url)) url <- "http://127.0.0.1:8000"
  list(
    url = sub("/+$", "", url),
    key = Sys.getenv("API_INTERNAL_KEY"),
    ip = {
      x <- trimws(as.character(ip %||% "")[1])
      if (is.na(x)) "" else x
    }
  )
}

api_header <- function(req, name, value) {
  do.call(httr2::req_headers, c(list(req), stats::setNames(list(value), name)))
}

api_request <- function(ctx, path) {
  req <- httr2::request(ctx$url) |>
    httr2::req_url_path_append(path) |>
    httr2::req_timeout(10) |>
    api_header("X-Internal-Key", ctx$key)
  if (nzchar(ctx$ip)) req <- api_header(req, "X-Client-IP", ctx$ip)
  # Single req_error() call: it stores both hooks at once, and callers need
  # the real status (404 = unknown token, 429 = rate limit) instead of an
  # exception. Only transport failures reach the tryCatch, and those map to
  # 503.
  httr2::req_error(req, is_error = ~ FALSE, body = function(resp) {
    msg <- tryCatch(httr2::resp_body_json(resp)$message, error = function(e) NULL)
    if (is.null(msg)) character() else as.character(msg)
  })
}

# GET /share-data/{token} -> the aggregated result, or NULL when the API
# answers 404/503 (unknown token, day not finished, database down). The page
# turns that into its own 404/503, so the caller never sees an httr2 error.
api_share_data <- function(ctx, token) {
  res <- tryCatch(
    api_request(ctx, file.path("share-data", token)) |>
      httr2::req_retry(max_tries = 2, is_transient = function(r) {
        httr2::resp_status(r) >= 500
      }) |>
      httr2::req_perform(),
    error = function(e) {
      # Without this a failed upstream becomes a bare 503 and the card has
      # nothing to say about why (the same gap share-email had).
      cat("share-data: request failed: ", conditionMessage(e), "\n",
          file = stderr())
      NULL
    }
  )
  if (is.null(res)) return(list(status = 503L, data = NULL))
  status <- httr2::resp_status(res)
  if (status != 200L) {
    cat("share-data: upstream ", status, " for ", token, "\n", file = stderr())
  }
  list(status = status,
       data = if (status == 200L) {
         httr2::resp_body_json(res, simplifyVector = TRUE)
       } else {
         NULL
       })
}

# POST /waitlist -> {message}. The per-IP limit (5/day) lives on the API side
# (5.4), so a 429 there is relayed as-is rather than retried.
api_waitlist <- function(ctx, email) {
  res <- tryCatch(
    api_request(ctx, "waitlist") |>
      httr2::req_body_json(list(email = email)) |>
      httr2::req_perform(),
    error = function(e) NULL
  )
  if (is.null(res)) return(list(status = 503L, message = ""))
  body <- tryCatch(httr2::resp_body_json(res, simplifyVector = TRUE),
                   error = function(e) list())
  list(status = httr2::resp_status(res),
       message = as.character(body$message %||% ""))
}
