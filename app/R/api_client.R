# Pure httr2 client for the plumber2 API. NO Shiny code in this file: it is
# also sourced inside the mirai daemons. Routes and payloads follow
# contract/openapi.yaml, the authoritative HTTP contract for the UI too --
# API_CONTRACT.md, the transitional 5-route list, was retired once the UI
# talked to the real endpoints.

api_base_url <- function() Sys.getenv("TAXI_API_URL", "http://127.0.0.1:8000")

# Everything a request needs: URL and internal key are read in the Shiny
# process and shipped to the daemon with the mirai, so the worker never
# depends on its own environment. The resume code comes from the session.
api_ctx <- function(ip = "", resume_code = "") {
  one <- function(x) {
    x <- as.character(x %||% "")[1]
    if (is.na(x)) "" else trimws(x)
  }
  list(
    url = api_base_url(),
    key = Sys.getenv("API_INTERNAL_KEY"),
    ip = one(ip),
    resume_code = one(resume_code)
  )
}

# `%||%` for the daemons/tests that source this file alone.
`%||%` <- function(x, y) if (is.null(x)) y else x

# httr2 1.3 dropped req_header() in favour of req_headers(), whose `...` needs
# literal names; the header names here are dynamic, so set them through a
# tiny wrapper that never has to quote a dashed name.
api_header <- function(req, name, value) {
  do.call(httr2::req_headers, c(list(req), stats::setNames(list(value), name)))
}

# X-Internal-Key on every call (403 without it), X-Client-IP on every call
# that has one (5.4: the rate limit only counts an IP sent with a valid key),
# X-Resume-Code only where the route demands it.
api_request <- function(ctx, path, resume = FALSE) {
  req <- request(ctx$url) |>
    req_url_path_append(path) |>
    req_timeout(15) |>
    api_header("X-Internal-Key", ctx$key)
  if (nzchar(ctx$ip)) req <- api_header(req, "X-Client-IP", ctx$ip)
  if (resume && nzchar(ctx$resume_code)) {
    req <- api_header(req, "X-Resume-Code", ctx$resume_code)
  }
  req |>
    req_error(body = function(resp) {
      msg <- tryCatch(resp_body_json(resp)$message, error = function(e) NULL)
      if (is.null(msg)) character() else as.character(msg)
    })
}

api_json <- function(req) {
  req |> req_perform() |> resp_body_json(simplifyVector = TRUE)
}

drop_nulls <- function(x) Filter(Negate(is.null), x)

iso_8601 <- function(x) {
  # The contract wants ISO 8601; the setup form accepts what a human types.
  x <- trimws(as.character(x %||% "")[1])
  if (!nzchar(x)) return("")
  parsed <- tryCatch(
    suppressWarnings(as.POSIXct(
      x, tz = "UTC",
      tryFormats = c("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S",
                     "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M",
                     "%Y-%m-%d %H:%M:%OS", "%Y-%m-%d")
    )),
    error = function(e) NA
  )
  if (is.na(parsed)) return(x)   # let the API answer with a 400
  format(parsed, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

# ---- models (phase 1) -------------------------------------------------------

# POST /recommend-start -> list(company, recommended_datetime, hour, week_day)
api_recommend_start <- function(ctx, datetime, company) {
  api_request(ctx, "recommend-start") |>
    req_body_json(list(datetime = iso_8601(datetime), company = company)) |>
    req_retry(max_tries = 3) |>          # idempotent, safe to retry
    api_json()
}

# POST /validate-trip-start -> list(is_optimal, better_company, better_datetime)
# better_* are absent (not null) when the start is already optimal.
api_validate_trip_start <- function(ctx, company, datetime, location_id) {
  api_request(ctx, "validate-trip-start") |>
    req_body_json(list(
      company = company,
      datetime = iso_8601(datetime),
      location_id = as.integer(location_id)
    )) |>
    api_json()
}

# ---- experiments (phase 3-4) ------------------------------------------------

# POST /experiments -> 201 with the one-time resume code and status "setup".
# The trajectories are computed in the background; poll api_get_state() until
# status becomes "in_progress". No retry: the create is rate limited (3/day
# per IP) and a duplicate would burn a slot.
api_create_experiment <- function(ctx, company, start_datetime, start_location_id,
                                  seed = NULL, email = NULL,
                                  marketing_consent = NULL, country = NULL) {
  api_request(ctx, "experiments") |>
    req_body_json(drop_nulls(list(
      company = company,
      start_datetime = iso_8601(start_datetime),
      start_location_id = as.integer(start_location_id),
      seed = if (is.null(seed) || !nzchar(trimws(as.character(seed)))) NULL
             else as.integer(seed),
      email = if (is.null(email) || !nzchar(trimws(as.character(email)))) NULL
              else trimws(as.character(email)),
      marketing_consent = if (is.null(marketing_consent)) NULL
                          else isTRUE(marketing_consent)
    ))) |>
    (\(req) if (!is.null(country) && nzchar(country)) {
      api_header(req, "CF-IPCountry", country)
    } else req)() |>
    api_json()
}

# GET /experiments/{id} -> full record (resume: requires X-Resume-Code).
api_get_experiment <- function(ctx, experiment_id) {
  api_request(ctx, file.path("experiments", experiment_id), resume = TRUE) |>
    req_retry(max_tries = 3) |>
    api_json()
}

# GET /experiments/{id}/state -> day state (resume: requires X-Resume-Code).
api_get_state <- function(ctx, experiment_id) {
  api_request(ctx, file.path("experiments", experiment_id, "state"),
              resume = TRUE) |>
    api_json()
}

# POST /experiments/{id}/decisions -> DayState after the decision. The trip
# must be the one currently offered, otherwise the API answers 409.
api_decide <- function(ctx, experiment_id, trip_id, accepted) {
  api_request(ctx, file.path("experiments", experiment_id, "decisions"),
              resume = TRUE) |>
    req_body_json(list(
      trip_id = as.integer(trip_id),
      accepted = isTRUE(accepted)
    )) |>
    api_json()
}

# POST /experiments/{id}/finish -> the finished Experiment record with the
# results. The route declares no requestBody (contract/openapi.yaml), and the
# real API answers it with or without one; dev/mock_api.R needs the request to
# carry a body before plumber2 dispatches the route at all, so an empty object
# is sent -- exactly what api/dev/e2e_experiments.sh does with `-d '{}'`.
api_finish <- function(ctx, experiment_id) {
  api_request(ctx, file.path("experiments", experiment_id, "finish"),
              resume = TRUE) |>
    httr2::req_body_raw(charToRaw("{}"), type = "application/json") |>
    api_json()
}

# POST /experiments/{id}/abandon -> the abandoned record.
api_abandon <- function(ctx, experiment_id) {
  api_request(ctx, file.path("experiments", experiment_id, "abandon"),
              resume = TRUE) |>
    api_json()
}

# POST /experiments/{id}/feedback -> {message}. Rating 1-5 is the only
# required field; the comment and the public-display consent are optional
# (contract FeedbackRequest, off by default).
api_feedback <- function(ctx, experiment_id, rating, comment = NULL,
                         public = FALSE) {
  api_request(ctx, file.path("experiments", experiment_id, "feedback"),
              resume = TRUE) |>
    req_body_json(drop_nulls(list(
      rating = as.integer(rating),
      comment = if (is.null(comment) || !nzchar(trimws(comment))) NULL
                else trimws(comment),
      public = isTRUE(public)
    ))) |>
    api_json()
}

# ---- sensitivity (phase 2) --------------------------------------------------

# POST /sensitivity -> three grids (original, pickup, drop-off) plus display
# metadata. X-Device: mobile switches the server to a 30x30 grid.
api_sensitivity <- function(ctx, experiment_id, trip_id,
                            pickup_id = NULL, dropoff_id = NULL,
                            grid_size = NULL, device = NULL) {
  req <- api_request(ctx, "sensitivity", resume = TRUE) |>
    req_body_json(drop_nulls(list(
      experiment_id = experiment_id,
      trip_id = as.integer(trip_id),
      pickup_id = if (is.null(pickup_id)) NULL else as.integer(pickup_id),
      dropoff_id = if (is.null(dropoff_id)) NULL else as.integer(dropoff_id),
      grid_size = if (is.null(grid_size)) NULL else as.integer(grid_size)
    )))
  if (!is.null(device) && nzchar(device)) req <- api_header(req, "X-Device", device)
  api_json(req)
}
