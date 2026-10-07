# POST /recommend-start (contract operationId recommendStart): deterministic
# next-valid-start lookup over ValidHoursToStartWorking.qs2, no model.

recommend_start_handler <- function(request, response, body) {
  if (!isTRUE(models_status()$valid_hours)) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }

  absent <- missing_fields(payload, c("datetime", "company"))
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

  body <- recommend_start_body(model_state$valid_hours, datetime)
  if (is.na(lubridate::ymd_hms(body$recommended_datetime, tz = "UTC", quiet = TRUE))) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }
  body$company <- payload$company

  response$body <- body[c("company", "recommended_datetime", "hour", "week_day")]
  plumber2::Break
}
