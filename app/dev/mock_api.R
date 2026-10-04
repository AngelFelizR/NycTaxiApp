# Mock plumber2 API implementing API_CONTRACT.md -- DEVELOPMENT ONLY.
# No real model: trips are random and the "policy" is a simple pay-per-hour rule.
# Run with:  Rscript dev/run_mock_api.R
# NOTE: written against plumber2's annotation syntax; not executed here (plumber2
# was not available), so adjust handler argument names if your plumber2 version differs.

best_company <- "Uber"
best_start   <- "2024-05-12 20:00"
shift_hours  <- 8
zones <- c("Queens - Saint Albans", "Manhattan - Alphabet City",
           "Queens - Jamaica", "Brooklyn - Williamsburg")

days <- new.env()   # day_id -> mutable day environment

new_trip <- function(from) {
  minutes <- sample(10:45, 1)
  list(pickup_zone = from,
       dropoff_zone = sample(setdiff(zones, from), 1),
       current_location = from,
       miles = round(minutes * 0.36),
       minutes = minutes,
       pay = round(minutes * 0.8 + runif(1, 0, 8)))
}
policy_accepts <- function(trip) trip$pay / trip$minutes * 60 >= 45

fmt_clock <- function(t) format(t, "%Y-%m-%d %H:%M:%S", tz = "UTC")

day_state <- function(id, d) {
  pending <- shift_hours - as.numeric(difftime(d$clock, d$t0, units = "hours"))
  n <- nrow(d$history) - 1
  list(day_id = id,
       finished = d$finished,
       clock = fmt_clock(d$clock),
       pending_hours = max(0, pending),
       pct_following_policy = if (n == 0) 100 else 100 * d$followed / n,
       history = d$history,
       trip = if (d$finished) NULL else d$trip)
}

#* @get /options
function() {
  list(companies = c("Lyft", "Uber"),
       zones = zones,
       default_start_dt = "2024-05-12 00:00")
}

#* @post /validate
function(body) {
  company_ok <- identical(body$company, best_company)
  dt_ok      <- identical(body$start_dt, best_start)
  list(optimal = company_ok && dt_ok,
       company_hint  = if (company_ok) "" else paste("Use", best_company, "for better results"),
       datetime_hint = if (dt_ok) "" else paste("Start at", best_start, "for better results"),
       message = if (company_ok && dt_ok) "Conditions are Perfect to get best results" else "")
}

#* @post /days
function(body) {
  id <- paste(sample(c(letters, 0:9), 8, replace = TRUE), collapse = "")
  t0 <- as.POSIXct(body$start_dt, format = "%Y-%m-%d %H:%M", tz = "UTC")
  d <- list2env(list(
    t0 = t0, clock = t0, location = body$start_zone,
    followed = 0, finished = FALSE,
    history = data.frame(step = 0, user = 0, policy = 0),
    trip = new_trip(body$start_zone)
  ), parent = emptyenv())
  assign(id, d, envir = days)
  day_state(id, d)
}

#* @post /days/<day_id>/decisions
function(day_id, body) {
  d <- get0(day_id, envir = days, inherits = FALSE)
  if (is.null(d)) stop("unknown day_id: ", day_id)

  accept <- isTRUE(body$accept)
  tr   <- d$trip
  rec  <- policy_accepts(tr)
  last <- d$history[nrow(d$history), ]
  d$history <- rbind(d$history, data.frame(
    step   = last$step + 1,
    user   = last$user   + if (accept) tr$pay else 0,
    policy = last$policy + if (rec)    tr$pay else 0))
  d$followed <- d$followed + (accept == rec)

  if (accept) { d$clock <- d$clock + tr$minutes * 60; d$location <- tr$dropoff_zone }
  else        { d$clock <- d$clock + 5 * 60 }

  if (as.numeric(difftime(d$clock, d$t0, units = "hours")) >= shift_hours) {
    d$finished <- TRUE
  } else {
    d$trip <- new_trip(d$location)
  }
  day_state(day_id, d)
}

#* @post /days/<day_id>/sensitivity
function(day_id, body) {
  mins <- seq(5, 60, by = 5)
  scenarios <- c("Original", "Pickup changed", "Drop-off changed")
  offsets   <- c(0, 3, -2)
  data.frame(
    scenario     = rep(scenarios, each = length(mins)),
    trip_minutes = rep(mins, times = length(scenarios)),
    min_pay      = unlist(lapply(offsets, function(o) round(mins * 0.75 + o, 1)))
  )
}
