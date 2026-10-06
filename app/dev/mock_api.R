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

# Simulated clock: 45 minutes per decision from a 00:00 start over an 8h
# shift, matching the shape the real simulator produces (section 3).
mock_pending <- function(n_decisions) max(0, 8 - n_decisions * 0.75)

mock_state <- function(day, status = day$status) {
  step <- length(day$decisions)
  pending <- mock_pending(step)
  # Whole minutes first: `step * 0.75 %% 1` would parse as step * (0.75 %% 1)
  # because R gives the %any% operators a tighter precedence than *.
  mins <- as.integer(round(step * 0.75 * 60))
  list(
    experiment_id = day$id,
    status = status,
    clock = sprintf("2024-05-12 %02d:%02d:00", mins %/% 60, mins %% 60),
    pending_hours = pending,
    pct_following_policy = 100,
    current_location_id = 161L,
    current_zone = "Midtown-Midtown South",
    # No offer once the shift is over: the real API answers 409 on a decision
    # then, and the UI calls /finish instead.
    next_trip = if (identical(status, "in_progress") && pending > 0)
                  mock_trip(step) else NA,
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
    email = payload$email %||% NULL,
    # An edited seed marks the result unofficial (section 3.3).
    seed_custom = nzchar(trimws(as.character(payload$seed %||% ""))),
    seed = suppressWarnings(as.integer(payload$seed %||% NA_integer_))
  )
  assign(id, day, envir = mock_env$days)
  assign(id, 0L, envir = mock_env$polls)

  body <- mock_state(day, status = "setup")
  body$model_progress <- 0L
  # One-time credential (contract CreatedExperiment.resume_code): the UI puts
  # it in the modal and sends it back as X-Resume-Code on every /experiments call.
  day$resume_code <- sprintf("mockresume%02d", mock_env$next_id)
  day$share_token <- paste0("s", gsub("-", "", substr(id, 1, 18)))
  assign(id, day, envir = mock_env$days)
  body$resume_code <- day$resume_code
  body$share_token <- day$share_token
  response$status <- 201L
  response$body <- body
  plumber2::Break
}

# GET /experiments/{id} -> the Experiment record (contract getExperiment; the
# resume flow reads it back with X-Resume-Code). Registered before the child
# routes on purpose: plumber2 only registers /experiments/<id>/... once the
# parent path exists.
mock_get_experiment <- function(request, response, id) {
  day <- get0(id, envir = mock_env$days, inherits = FALSE)
  if (is.null(day)) {
    return(mock_fail(response, 404L, "not_found", "Experiment not found."))
  }
  if (!identical(request$get_header("x-resume-code"), day$resume_code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  response$body <- mock_experiment(day)
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
  # Shift over: no offer left, so the real API answers 409 and the UI is
  # expected to have called /finish instead of deciding anything.
  if (mock_pending(length(day$decisions)) <= 0) {
    return(mock_fail(response, 409L, "conflict", "The day is already over."))
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

# A day's three trajectories in miniature: the same shape the real simulator
# writes into `decisions`, so Results can be exercised without models.
mock_result <- function(day) {
  step <- length(day$decisions)
  user <- step * 18.5
  policy <- step * 19.2
  baseline <- step * 12.1
  accepted <- sum(vapply(day$decisions, function(d) isTRUE(d$accepted),
                         logical(1)))
  uw <- user / 8
  pw <- policy / 8
  bw <- baseline / 8
  # Section 3.10 precedence, evaluated the way the API does it.
  outcome <- if (accepted == 0) "no_rides"
    else if (uw > pw + 0.01) "beat_model"
    else if (abs(uw - pw) <= 0.01) "tied_model"
    else if (uw > bw) "beat_baseline"
    else "lost_to_baseline"
  list(
    final_user_wage = round(uw, 2),
    final_policy_wage = round(pw, 2),
    final_baseline_wage = round(bw, 2),
    pct_following_policy = 100,
    outcome = outcome,
    user_percentile = 62.5,
    trips_accepted = accepted,
    trips_rejected = step - accepted
  )
}

# POST /finish answers the whole Experiment record, not a DayState -- the UI
# reads company, model_version and seed_is_custom from it (technical details).
mock_experiment <- function(day) {
  list(
    id = day$id,
    status = "finished",
    company = day$company %||% "Lyft",
    start_datetime = "2024-05-12T00:00:00Z",
    start_location_id = 61L,
    seed = if (isTRUE(day$seed_custom)) as.numeric(day$seed) else 0,
    seed_is_custom = isTRUE(day$seed_custom),
    model_version = "0.0.1-data",
    app_version = "0.1.0",
    created_at = "2024-05-12T00:00:00Z",
    updated_at = "2024-05-12T08:30:00Z",
    finished_at = "2024-05-12T08:30:00Z",
    share_token = day$share_token %||% "",
    result = mock_result(day),
    feedback = NA
  )
}

# `body` is unused (the contract declares no requestBody for /finish), but a
# POST route only dispatches here when the request carries a JSON body: without
# the formal plumber2 never reads it and the route falls through to the
# catch-all. The client sends "{}" for the same reason -- see api_client.R.
mock_finish <- function(request, response, id, body) {
  day <- get0(id, envir = mock_env$days, inherits = FALSE)
  if (is.null(day)) {
    return(mock_fail(response, 404L, "not_found", "Experiment not found."))
  }
  if (!identical(request$get_header("x-resume-code"), day$resume_code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  if (identical(day$status, "setup")) {
    return(mock_fail(response, 409L, "conflict", "The day has not started yet."))
  }
  day$status <- "finished"
  assign(id, day, envir = mock_env$days)
  response$body <- mock_experiment(day)
  plumber2::Break
}

# POST /experiments/{id}/feedback -> {message} (contract MessageResponse).
mock_feedback <- function(request, response, id, body) {
  day <- get0(id, envir = mock_env$days, inherits = FALSE)
  if (is.null(day)) {
    return(mock_fail(response, 404L, "not_found", "Experiment not found."))
  }
  if (!identical(request$get_header("x-resume-code"), day$resume_code)) {
    return(mock_fail(response, 403L, "forbidden",
                     "Invalid or missing X-Resume-Code header."))
  }
  payload <- mock_body(body)
  rating <- suppressWarnings(as.integer(payload$rating %||% NA))
  if (length(rating) != 1L || is.na(rating) || rating < 1L || rating > 5L) {
    return(mock_fail(response, 422L, "unprocessable_entity",
                     "rating must be an integer between 1 and 5."))
  }
  day$feedback <- list(rating = rating,
                       comment = payload$comment %||% NA,
                       public = isTRUE(payload$public))
  assign(id, day, envir = mock_env$days)
  response$body <- list(message = "Feedback saved.")
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
  api <- plumber2::api_get(api, "/experiments/<id>", mock_get_experiment,
                           serializers = js)
  api <- plumber2::api_get(api, "/experiments/<id>/state", mock_get_state,
                           serializers = js)
  api <- plumber2::api_post(api, "/experiments/<id>/decisions", mock_decide,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/experiments/<id>/finish", mock_finish,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/experiments/<id>/feedback", mock_feedback,
                            serializers = js, parsers = pj)
  api <- plumber2::api_post(api, "/sensitivity", mock_sensitivity,
                            serializers = js, parsers = pj)
  # Same shape as api/plumber.R: a trailing catch-all so an unknown path
  # answers 404 "No route matches." instead of an empty 200.
  api <- plumber2::api_any(api, "/*", function(request, response, ...) {
    mock_fail(response, 404L, "not_found", "No route matches.")
  }, serializers = js)
  api
}
