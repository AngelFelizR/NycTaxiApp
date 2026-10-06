# Mock plumber2 API for the UI tests -- DEVELOPMENT ONLY, never deployed.
#
# It speaks the real routes from contract/openapi.yaml (validate-trip-start,
# experiments, state, decisions, sensitivity) with canned answers and an
# in-memory day, so the shinytest2 flow test can drive the app without the
# models, Postgres or Redis, and without burning the 3-experiments-per-IP
# rate limit of the real API.
#
# It also records the X-Client-IP header it received, which is how the phase-4
# test proves that the app forwards the address it saw in its own request.
#
# Run it with:  Rscript dev/run_mock_api.R   (from app/, port 8010)

mock_env <- new.env(parent = emptyenv())
mock_env$days <- new.env(parent = emptyenv())
mock_env$next_id <- 1L
mock_env$polls <- new.env(parent = emptyenv())
mock_env$last_ip <- NULL
mock_env$last_key <- NULL

mock_serializers <- function() {
  list("application/json" = plumber2::format_unboxed())
}

mock_parsers <- function() {
  list(
    "application/json" = function(raw, directives) raw,
    "*/*" = function(raw, directives) raw
  )
}

mock_body <- function(body) {
  txt <- tryCatch(rawToChar(body), error = function(e) NULL)
  if (is.null(txt) || !nzchar(txt)) return(list())
  tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE),
           error = function(e) list())
}

# Every route is behind X-Internal-Key (403 without it), and the address the
# app forwarded is kept for the test to assert on. Returns Next/ Break the way
# the real internal_auth_header does.
mock_auth <- function(request, response) {
  # Record only what is actually there: the test reads /__last, and that call
  # carries no X-Client-IP, so overwriting unconditionally would wipe it.
  key <- request$get_header("x-internal-key")
  ip  <- request$get_header("x-client-ip")
  if (!is.null(key) && nzchar(key)) mock_env$last_key <- key
  if (!is.null(ip) && nzchar(ip))   mock_env$last_ip  <- ip
  if (is.null(mock_env$last_key) || !nzchar(mock_env$last_key)) {
    response$status <- 403L
    response$body <- list(error = "forbidden",
                          message = "Invalid or missing X-Internal-Key header.")
    return(plumber2::Break)
  }
  plumber2::Next
}

mock_fail <- function(response, status, error, message) {
  response$status <- as.integer(status)
  response$body <- list(error = error, message = message)
  plumber2::Break
}

mock_trip <- function(step) {
  list(
    trip_id = 88400L + as.integer(step),
    pulocation_id = 61L,
    dolocation_id = 161L,
    pickup_zone = "Queens - Saint Albans",
    dropoff_zone = "Midtown-Midtown South",
    miles = 9.4,
    trip_time_sec = 1500L,
    driver_pay = 20.75,
    tips = 1.5,
    request_datetime = "2024-05-12T04:30:00Z",
    recommendation = if (step %% 2 == 0) "accept" else "reject",
    probability = 0.93
  )
}

mock_state <- function(day, status = day$status) {
  step <- length(day$decisions)
  # 45 simulated minutes per decision (trip + idle), from a 00:00 start, so
  # accepting a trip visibly moves the clock and drains pending_hours.
  elapsed <- step * 0.75
  list(
    experiment_id = day$id,
    status = status,
    clock = sprintf("2024-05-12 %02d:%02d:00",
                    as.integer(elapsed), as.integer((elapsed %% 1) * 60)),
    pending_hours = max(0, 8 - elapsed),
    pct_following_policy = 100,
    current_location_id = 161L,
    current_zone = "Midtown-Midtown South",
    next_trip = if (identical(status, "in_progress")) mock_trip(step) else NA,
    history = c(
      list(list(step = 0L, user = 0, policy = 0, baseline = 0)),
      lapply(seq_len(step), function(i) {
        list(step = i, user = i * 18.5, policy = i * 19.2, baseline = i * 12.1)
      })
    ),
    result = NA
  )
}

# ---- handlers ---------------------------------------------------------------

mock_health <- function(request, response) {
  response$body <- list(status = "ok")
  plumber2::Break
}

mock_validate <- function(request, response, body) {
  payload <- mock_body(body)
  company <- payload$company %||% "Lyft"
  datetime <- payload$datetime %||% ""
  if (identical(company, "Uber") && startsWith(datetime, "2024-05-12T20")) {
    response$body <- list(is_optimal = TRUE)
  } else {
    response$body <- list(
      is_optimal = FALSE,
      better_company = "Uber",
      better_datetime = "2024-05-12T20:00:00Z"
    )
  }
  plumber2::Break
}

mock_recommend <- function(request, response, body) {
  payload <- mock_body(body)
  response$body <- list(
    company = payload$company %||% "Uber",
    recommended_datetime = "2024-05-12T20:00:00Z",
    hour = 20L,
    week_day = "saturday"
  )
  plumber2::Break
}

mock_create <- function(request, response, body) {
  payload <- mock_body(body)
  if (is.null(payload$company) || is.null(payload$start_datetime) ||
      is.null(payload$start_location_id)) {
    return(mock_fail(response, 400L, "bad_request", "Missing required field(s)."))
  }
  id <- sprintf("00000000-0000-4000-8000-%012d", mock_env$next_id)
  mock_env$next_id <- mock_env$next_id + 1L
  day <- list(
    id = id,
    status = "setup",
    decisions = list(),
    company = payload$company,
    email = payload$email %||% NULL
  )
  assign(id, day, envir = mock_env$days)
  assign(id, 0L, envir = mock_env$polls)

  body <- mock_state(day, status = "setup")
  body$model_progress <- 0L
  # One-time credential (contract CreatedExperiment.resume_code): the UI puts
  # it in the modal and sends it back as X-Resume-Code on every /experiments call.
  day$resume_code <- sprintf("mockresume%02d", mock_env$next_id)
  assign(id, day, envir = mock_env$days)
  body$resume_code <- day$resume_code
  body$share_token <- paste0("s", gsub("-", "", substr(id, 1, 18)))
  response$status <- 201L
  response$body <- body
  plumber2::Break
}

mock_get_state <- function(request, response, id) {
  code <- request$get_header("x-resume-code")
  if (is.null(code) || !nzchar(code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  day <- get0(id, envir = mock_env$days, inherits = FALSE)
  if (is.null(day)) {
    return(mock_fail(response, 404L, "not_found", "Experiment not found."))
  }
  if (!identical(code, day$resume_code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  polls <- get0(id, envir = mock_env$polls, inherits = FALSE)
  if (identical(day$status, "setup")) {
    assign(id, polls + 1L, envir = mock_env$polls)
    # Two polls in setup, then the trajectories are "ready": the app keeps
    # polling until the status flips, which is exactly what this simulates.
    if (polls + 1L >= 2L) {
      day$status <- "in_progress"
      assign(id, day, envir = mock_env$days)
    }
  }
  body <- mock_state(day)
  if (identical(body$status, "setup")) body$model_progress <- 50L
  response$body <- body
  plumber2::Break
}

mock_decide <- function(request, response, id, body) {
  code <- request$get_header("x-resume-code")
  if (is.null(code) || !nzchar(code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  day <- get0(id, envir = mock_env$days, inherits = FALSE)
  if (is.null(day)) {
    return(mock_fail(response, 404L, "not_found", "Experiment not found."))
  }
  if (!identical(code, day$resume_code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  if (!identical(day$status, "in_progress")) {
    return(mock_fail(response, 409L, "conflict", "This experiment is not in progress."))
  }
  payload <- mock_body(body)
  if (is.null(payload$trip_id)) {
    return(mock_fail(response, 400L, "bad_request", "Missing required field(s): trip_id."))
  }
  if (length(day$decisions) >= 12L) {
    # Shift over: the app should move on to Results.
    day$status <- "finished"
    assign(id, day, envir = mock_env$days)
    body <- mock_state(day, status = "finished")
    response$body <- body
    return(plumber2::Break)
  }
  day$decisions <- c(day$decisions, list(list(trip_id = payload$trip_id,
                                              accepted = isTRUE(payload$accepted))))
  assign(id, day, envir = mock_env$days)
  response$body <- mock_state(day)
  plumber2::Break
}

mock_sensitivity <- function(request, response, body) {
  grid <- lapply(seq(600, 3000, by = 600), function(tt) {
    lapply(seq(5, 45, by = 10), function(pay) {
      list(trip_time_sec = as.integer(tt), driver_pay = pay,
           prob = min(0.99, max(0.01, pay / (tt / 60) / 1.2)))
    })
  })
  grid <- unlist(grid, recursive = FALSE)
  response$body <- list(
    recommendation = "accept",
    pickup_suggested = 132L,
    dropoff_suggested = 144L,
    meta = list(
      threshold = 0.9,
      original_label = "PU (61) Queens - Saint Albans / DO (161) Midtown-Midtown South",
      pu_label = "(132) Queens - JFK Airport",
      do_label = "(144) Manhattan - Little Italy/NoLiTa"
    ),
    grid_original = grid,
    grid_pu = grid,
    grid_do = grid
  )
  plumber2::Break
}

mock_last_seen <- function(request, response) {
  response$body <- list(
    ip = if (is.null(mock_env$last_ip)) "" else mock_env$last_ip,
    key = if (is.null(mock_env$last_key)) "" else mock_env$last_key
  )
  plumber2::Break
}

mock_finish <- function(request, response, id) {
  day <- get0(id, envir = mock_env$days, inherits = FALSE)
  if (is.null(day)) {
    return(mock_fail(response, 404L, "not_found", "Experiment not found."))
  }
  day$status <- "finished"
  assign(id, day, envir = mock_env$days)
  response$body <- mock_state(day, status = "finished")
  plumber2::Break
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---- wiring -----------------------------------------------------------------

mock_api <- function(host = "127.0.0.1", port = 8010L) {
  js <- mock_serializers()
  pj <- mock_parsers()
  api <- plumber2::api(host = host, port = port)
  api <- plumber2::api_any_header(api, "/*", function(request, response, ...) {
    mock_auth(request, response)
  }, serializers = js)
  api <- plumber2::api_get(api, "/health", mock_health, serializers = js)
  api <- plumber2::api_get(api, "/__last", mock_last_seen, serializers = js)
  api <- plumber2::api_post(api, "/validate-trip-start", mock_validate,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/recommend-start", mock_recommend,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/experiments", mock_create,
                            serializers = js, parsers = pj)
  api <- plumber2::api_get(api, "/experiments/<id>/state", mock_get_state,
                           serializers = js)
  api <- plumber2::api_post(api, "/experiments/<id>/decisions", mock_decide,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/experiments/<id>/finish", mock_finish,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/sensitivity", mock_sensitivity,
                            serializers = js, parsers = pj)
  api
}
