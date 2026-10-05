# Deterministic valid-hours lookup for POST /recommend-start (section 4.3).
# Same algorithm as the training reference optimize_trip_start_time():
# current cycle = (wday - 1) * 24 + hour with wday 1 = Sunday, next valid
# cycle strictly greater, with a +168h copy of the table to wrap over the
# week boundary; the result is floored to the hour plus the wait duration.

next_valid_start <- function(valid_hours, datetime) {
  if (is.null(valid_hours) || nrow(valid_hours) == 0) return(as.POSIXct(NA))
  current <- (lubridate::wday(datetime) - 1L) * 24L + lubridate::hour(datetime)
  cycles <- valid_hours$week_cycle
  candidates <- c(cycles, cycles + 168L)
  next_cycle <- min(candidates[candidates > current])
  lubridate::floor_date(datetime, unit = "hour") + (next_cycle - current) * 3600
}

recommend_start_body <- function(valid_hours, datetime) {
  recommended <- next_valid_start(valid_hours, datetime)
  list(
    company = NULL, # filled by the endpoint (echo of the request)
    recommended_datetime = iso_utc(recommended),
    hour = as.integer(lubridate::hour(recommended)),
    week_day = week_day_names()[lubridate::wday(recommended)]
  )
}
