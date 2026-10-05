# POST /predict (contract operationId predict): accept/reject inference for
# one trip. Frame layout mirrors the training recipe: zone ids become
# character, trip_time_sec maps to trip_time, performance columns were
# additional-info at prep time and are fed as NA (verified inert), accepted
# is probability > 0.90 (fixed policy threshold).

predict_handler <- function(request, response, body) {
  trace <- nzchar(Sys.getenv("API_TRACE"))
  t0 <- if (trace) proc.time()[["elapsed"]]
  if (!isTRUE(models_status()$policy)) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }

  required <- c(
    "pulocation_id", "dolocation_id", "trip_miles",
    "trip_time_sec", "driver_pay", "request_datetime"
  )
  absent <- missing_fields(payload, required)
  if (length(absent) > 0) {
    return(api_error(
      response, 400L, "bad_request",
      paste0("Missing required field(s): ", paste(absent, collapse = ", "), ".")
    ))
  }

  if (!is_zone_id(payload$pulocation_id) || !is_zone_id(payload$dolocation_id)) {
    if (!is_wholenumber(payload$pulocation_id) || !is_wholenumber(payload$dolocation_id)) {
      return(api_error(response, 400L, "bad_request", "Zone ids must be integers."))
    }
    return(api_error(response, 422L, "unprocessable_entity", "Zone ids must be between 1 and 265."))
  }
  if (!is_number(payload$trip_miles)) {
    return(api_error(response, 400L, "bad_request", "trip_miles must be a number."))
  }
  if (!is_wholenumber(payload$trip_time_sec)) {
    return(api_error(response, 400L, "bad_request", "trip_time_sec must be an integer."))
  }
  if (!is_number(payload$driver_pay)) {
    return(api_error(response, 400L, "bad_request", "driver_pay must be a number."))
  }
  if (!is_string(payload$request_datetime)) {
    return(api_error(response, 400L, "bad_request", "request_datetime must be a string."))
  }
  datetime <- lubridate::ymd_hms(payload$request_datetime, tz = "UTC", quiet = TRUE)
  if (is.na(datetime)) {
    return(api_error(response, 400L, "bad_request", "request_datetime must be ISO 8601."))
  }
  if (!is.null(payload$company) && !valid_company(payload$company)) {
    return(api_error(response, 400L, "bad_request", "company must be one of: Lyft, Uber."))
  }
  if (!is.null(payload$hvfhs_license_num) &&
    (!is_string(payload$hvfhs_license_num) || !nzchar(payload$hvfhs_license_num))) {
    return(api_error(response, 400L, "bad_request", "hvfhs_license_num must be a non-empty string."))
  }
  if (!is.null(payload$tips) && !is_number(payload$tips)) {
    return(api_error(response, 400L, "bad_request", "tips must be a number."))
  }
  if (!is.null(payload$trip_id) && !is_wholenumber(payload$trip_id)) {
    return(api_error(response, 400L, "bad_request", "trip_id must be an integer."))
  }

  if (payload$trip_miles <= 0) {
    return(api_error(response, 422L, "unprocessable_entity", "trip_miles must be greater than 0."))
  }
  if (payload$trip_time_sec < 1) {
    return(api_error(response, 422L, "unprocessable_entity", "trip_time_sec must be at least 1 second."))
  }
  if (payload$driver_pay < 0) {
    return(api_error(response, 422L, "unprocessable_entity", "driver_pay must not be negative."))
  }
  if (!is.null(payload$tips) && payload$tips < 0) {
    return(api_error(response, 422L, "unprocessable_entity", "tips must not be negative."))
  }

  hvfhs <- payload$hvfhs_license_num
  if (is.null(hvfhs)) {
    hvfhs <- if (!is.null(payload$company)) company_to_hvfhs(payload$company) else "HV0003"
  }

  frame <- data.frame(
    PULocationID = as.character(payload$pulocation_id),
    DOLocationID = as.character(payload$dolocation_id),
    hvfhs_license_num = hvfhs,
    trip_miles = payload$trip_miles,
    driver_pay = payload$driver_pay,
    request_datetime = datetime,
    trip_time = payload$trip_time_sec,
    trip_id = if (is.null(payload$trip_id)) NA_real_ else as.numeric(payload$trip_id),
    performance_per_hour = NA_real_,
    percentile_75_performance = NA_real_,
    stringsAsFactors = FALSE
  )
  if (!is.null(payload$tips)) frame$tips <- payload$tips

  t_model <- if (trace) proc.time()[["elapsed"]]
  probability <- tryCatch(
    policy_probability(frame),
    error = function(e) {
      message("predict failed: ", conditionMessage(e))
      NA_real_
    }
  )
  if (length(probability) != 1L || is.na(probability)) {
    return(api_error(response, 500L, "internal_error", "Prediction failed."))
  }
  if (trace) {
    cat(sprintf(
      "predict trace: validate=%dms model=%dms\n",
      round((t_model - t0) * 1000),
      round((proc.time()[["elapsed"]] - t_model) * 1000)
    ), file = stderr())
  }

  response$body <- list(
    accepted = probability > policy_threshold,
    probability = probability
  )
  plumber2::Break
}
