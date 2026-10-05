# POST /validate-trip-start (contract operationId validateTripStart): runs
# the decision-tree workflow. When the start is not high-value the better_*
# fields follow the training policy of optimize_trip_start_time(): try the
# same datetime with Uber, otherwise the next valid hour from the lookup.
# better_company/better_datetime are null when is_optimal is true.

validate_trip_start_handler <- function(request, response, body) {
  if (!isTRUE(models_status()$start_validator) || !isTRUE(models_status()$valid_hours)) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }

  absent <- missing_fields(payload, c("company", "datetime", "location_id"))
  if (length(absent) > 0) {
    return(api_error(
      response, 400L, "bad_request",
      paste0("Missing required field(s): ", paste(absent, collapse = ", "), ".")
    ))
  }
  if (!valid_company(payload$company)) {
    return(api_error(response, 400L, "bad_request", "company must be one of: Lyft, Uber."))
  }
  if (!is_string(payload$datetime)) {
    return(api_error(response, 400L, "bad_request", "datetime must be a string."))
  }
  datetime <- lubridate::ymd_hms(payload$datetime, tz = "UTC", quiet = TRUE)
  if (is.na(datetime)) {
    return(api_error(response, 400L, "bad_request", "datetime must be ISO 8601."))
  }
  if (!is_wholenumber(payload$location_id)) {
    return(api_error(response, 400L, "bad_request", "location_id must be an integer."))
  }
  if (payload$location_id < 1 || payload$location_id > 265) {
    return(api_error(response, 422L, "unprocessable_entity", "location_id must be between 1 and 265."))
  }

  is_high <- tryCatch(
    start_is_high_value(payload$company, datetime, payload$location_id),
    error = function(e) {
      message("validate-trip-start failed: ", conditionMessage(e))
      NA
    }
  )
  if (!is.logical(is_high) || length(is_high) != 1L || is.na(is_high)) {
    return(api_error(response, 500L, "internal_error", "Prediction failed."))
  }

  if (is_high) {
    # better_company/better_datetime are optional in the contract; omitted
    # (not null) when the start is already optimal.
    response$body <- list(is_optimal = TRUE)
    return(plumber2::Break)
  }

  uber_now <- tryCatch(
    start_is_high_value("Uber", datetime, payload$location_id),
    error = function(e) NA
  )
  better_datetime <- if (identical(uber_now, TRUE)) {
    datetime
  } else {
    next_valid_start(model_state$valid_hours, datetime)
  }

  response$body <- list(
    is_optimal = FALSE,
    better_company = "Uber",
    better_datetime = iso_utc(better_datetime)
  )
  plumber2::Break
}
