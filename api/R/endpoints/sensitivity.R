# POST /sensitivity (contract operationId sensitivity): three decision grids
# for one dataset trip plus display metadata (section 5.5). Cached in Redis as
# sens:{experiment_id}:{trip_id}:{pu}:{do} with a 1h TTL; the grid size is kept
# in the cached value (the contract key has no grid slot, so a mobile/desktop
# collision on the same key must not serve the wrong grid). Timing is always
# logged (section 8: "timing of /sensitivity always logged").

sensitivity_handler <- function(request, response, body) {
  t0 <- proc.time()[["elapsed"]]
  if (!isTRUE(models_status()$policy) || !trip_data_ready()) {
    return(api_error(
      response, 503L, "service_unavailable", "Models or trip data are not loaded."
    ))
  }

  if (is.null(request$get_header("x-client-ip"))) {
    return(api_error(
      response, 400L, "bad_request", "Missing required header: X-Client-IP."
    ))
  }
  device <- request$get_header("x-device")
  if (!is.null(device) && !device %in% c("mobile", "desktop")) {
    return(api_error(
      response, 400L, "bad_request", "X-Device must be one of: mobile, desktop."
    ))
  }

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }

  absent <- missing_fields(payload, c("experiment_id", "trip_id"))
  if (length(absent) > 0) {
    return(api_error(
      response, 400L, "bad_request",
      paste0("Missing required field(s): ", paste(absent, collapse = ", "), ".")
    ))
  }
  if (!is_string(payload$experiment_id) || !grepl(
    "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    payload$experiment_id
  )) {
    return(api_error(response, 400L, "bad_request", "experiment_id must be a UUID."))
  }
  if (!is_wholenumber(payload$trip_id)) {
    return(api_error(response, 400L, "bad_request", "trip_id must be an integer."))
  }
  trip <- trip_row(payload$trip_id)
  if (is.null(trip)) {
    return(api_error(response, 404L, "not_found", "Trip not found."))
  }

  for (field in c("pickup_id", "dropoff_id")) {
    value <- payload[[field]]
    if (is.null(value)) next
    if (!is_wholenumber(value)) {
      return(api_error(
        response, 400L, "bad_request", paste0(field, " must be an integer.")
      ))
    }
    if (value < 1 || value > 265) {
      return(api_error(
        response, 422L, "unprocessable_entity",
        paste0(field, " must be between 1 and 265.")
      ))
    }
  }

  grid_len <- 50L
  if (!is.null(payload$grid_size)) {
    if (!is_wholenumber(payload$grid_size)) {
      return(api_error(response, 400L, "bad_request", "grid_size must be an integer."))
    }
    if (payload$grid_size < 10 || payload$grid_size > 100) {
      return(api_error(
        response, 422L, "unprocessable_entity",
        "grid_size must be between 10 and 100."
      ))
    }
    grid_len <- as.integer(payload$grid_size)
  }
  if (identical(device, "mobile")) grid_len <- 30L

  base <- sensitivity_base_frame(trip)
  resolved <- tryCatch({
    candidates <- sensitivity_zone_candidates(trip$PULocationID)
    pu <- if (is.null(payload$pickup_id)) {
      select_zone_with_high_change(base, candidates, "PULocationID")
    } else {
      as.integer(payload$pickup_id)
    }
    candidates_do <- sensitivity_zone_candidates(trip$DOLocationID)
    do <- if (is.null(payload$dropoff_id)) {
      select_zone_with_high_change(base, candidates_do, "DOLocationID")
    } else {
      as.integer(payload$dropoff_id)
    }
    list(pu = pu, do = do)
  }, error = function(e) {
    message("sensitivity zone selection failed: ", conditionMessage(e))
    NULL
  })
  if (is.null(resolved)) {
    return(api_error(response, 500L, "internal_error", "Prediction failed."))
  }
  pu_zone <- resolved$pu
  do_zone <- resolved$do

  key <- sprintf(
    "sens:%s:%s:%s:%s", payload$experiment_id, trip$trip_id, pu_zone, do_zone
  )
  cached <- redis_get(key)
  if (is.character(cached) && nzchar(cached)) {
    # simplifyVector = TRUE brings the grid arrays back as data.frames, which
    # format_unboxed serialises far faster than 7.5k nested row lists (the
    # difference is ~2s on the wire for a 50x50 payload).
    parsed <- tryCatch(jsonlite::fromJSON(cached), error = function(e) NULL)
    if (is.list(parsed) && is.data.frame(parsed$body$grid_original) &&
      identical(as.integer(parsed$grid_size), grid_len)
    ) {
      res <- parsed$body
      # JSON null round-trips as NULL; the serializer turns NULL into {}
      # instead of null, so restore the contract's NA.
      if (is.null(res$pickup_suggested)) res$pickup_suggested <- NA_integer_
      if (is.null(res$dropoff_suggested)) res$dropoff_suggested <- NA_integer_
      response$body <- res
      log_sensitivity_timing(t0, hit = TRUE, grid_len, trip$trip_id)
      return(plumber2::Break)
    }
  }

  t_compute <- proc.time()[["elapsed"]]
  base_prob <- tryCatch(
    policy_probability(base),
    error = function(e) NA_real_
  )
  if (length(base_prob) != 1L || is.na(base_prob)) {
    return(api_error(response, 500L, "internal_error", "Prediction failed."))
  }
  grids <- tryCatch(
    compute_decision_grid(base, pu_zone, do_zone, grid_len),
    error = function(e) {
      message("sensitivity failed: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(grids)) {
    return(api_error(response, 500L, "internal_error", "Grid computation failed."))
  }

  original_label <- sprintf(
    "PU %s / DO %s", zone_label(trip$PULocationID), zone_label(trip$DOLocationID)
  )
  res <- list(
    recommendation = if (base_prob > sensitivity_threshold) "accept" else "reject",
    pickup_suggested = if (is.null(payload$pickup_id)) pu_zone else NA_integer_,
    dropoff_suggested = if (is.null(payload$dropoff_id)) do_zone else NA_integer_,
    meta = list(
      threshold = sensitivity_threshold,
      original_label = original_label,
      pu_label = zone_label(pu_zone),
      do_label = zone_label(do_zone),
      subtitle_html = paste0("<b>Original:</b> ", original_label),
      original_point = list(
        trip_time_sec = as.integer(trip$trip_time),
        driver_pay = trip$driver_pay
      )
    ),
    grid_original = grids$original,
    grid_pu = grids$pu,
    grid_do = grids$do
  )

  # Cache the response in the same shape the serializer emits, plus the grid
  # size guard (see the key note above). digits = 4 matches format_unboxed().
  stored <- jsonlite::toJSON(
    list(grid_size = grid_len, body = res),
    auto_unbox = TRUE, na = "null", digits = 4
  )
  redis_setex(key, stored, 3600L)

  response$body <- res
  log_sensitivity_timing(t0, hit = FALSE, grid_len, trip$trip_id,
                         compute_ms = round((proc.time()[["elapsed"]] - t_compute) * 1000))
  plumber2::Break
}

# Timing of /sensitivity is always logged (section 8), cached or not.
log_sensitivity_timing <- function(t0, hit, grid_len, trip_id, compute_ms = NULL) {
  cat(sprintf(
    "sensitivity: hit=%s ms=%d grid=%d trip=%s%s\n",
    if (hit) "TRUE" else "FALSE",
    round((proc.time()[["elapsed"]] - t0) * 1000),
    grid_len, trip_id,
    if (is.null(compute_ms)) "" else paste0(" compute=", compute_ms, "ms")
  ), file = stderr())
}
