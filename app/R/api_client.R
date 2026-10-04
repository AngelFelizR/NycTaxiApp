# Pure httr2 client for the plumber2 API. NO Shiny code in this file: it is also
# sourced inside the mirai daemons. See API_CONTRACT.md for routes and payloads.

api_base_url <- function() Sys.getenv("TAXI_API_URL", "http://127.0.0.1:8000")

api_request <- function(...) {
  request(api_base_url()) |>
    req_url_path_append(...) |>
    req_timeout(15) |>
    req_error(body = function(resp) {
      msg <- tryCatch(resp_body_json(resp)$message, error = function(e) NULL)
      if (is.null(msg)) character() else as.character(msg)
    })
}

api_json <- function(req) {
  req |> req_perform() |> resp_body_json(simplifyVector = TRUE)
}

drop_nulls <- function(x) Filter(Negate(is.null), x)

# GET /options -> list(companies, zones, default_start_dt)
api_options <- function() {
  api_request("options") |>
    req_retry(max_tries = 3) |>      # idempotent, safe to retry
    api_json()
}

# POST /validate -> list(optimal, company_hint, datetime_hint, message)
api_validate <- function(company, start_dt, start_zone) {
  api_request("validate") |>
    req_body_json(list(company = company, start_dt = start_dt,
                       start_zone = start_zone)) |>
    api_json()
}

# POST /days -> day state (see contract)
api_create_day <- function(company, start_dt, start_zone) {
  api_request("days") |>
    req_body_json(list(company = company, start_dt = start_dt,
                       start_zone = start_zone)) |>
    api_json()
}

# POST /days/{id}/decisions -> new day state
api_decide <- function(day_id, accept) {
  api_request("days", day_id, "decisions") |>
    req_body_json(list(accept = accept)) |>
    api_json()
}

# POST /days/{id}/sensitivity -> data.frame(scenario, trip_minutes, min_pay)
api_sensitivity <- function(day_id, pickup_zone = NULL, dropoff_zone = NULL) {
  api_request("days", day_id, "sensitivity") |>
    req_body_json(drop_nulls(list(pickup_zone = pickup_zone,
                                  dropoff_zone = dropoff_zone))) |>
    api_json()
}
