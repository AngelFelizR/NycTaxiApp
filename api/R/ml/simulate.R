# One simulated day (master doc section 3): a port of the prototype's
# simulate_trips() (~/r-projects/NycTaxi, reference only) onto the in-memory
# candidate_trips() search of data/trips.R. Three trajectories share the seed
# and the starting conditions and diverge only through their decisions:
#
#   policy    follows the XGBoost recommendation (P > 0.90), decline penalty
#   baseline  always takes the first trip found (chronological order)
#   user      replays the stored decisions and stops at the first undecided
#             offer, which becomes `pending` (state / next_trip)
#
# Fixed rules (section 3): an 8h shift plus one 30-minute break taken after
# 4h once a trip finishes, an expanding search window (1 -> 3 -> 5 -> +2 miles
# every 2 minutes), the WAV rule (the simulated taxi is not wheelchair
# accessible, so only wav_match_flag == "N" trips are eligible), and the
# shift limit start + 8h30 (a trip requested inside the window may finish
# after it).
#
# Decline penalty: the prototype waits 3 seconds after a rejected request.
# Ported literally, a player who rejects everything would face thousands of
# decisions before 8h30 elapse (the dataset has a median of ~9 eligible
# requests per minute inside a 1-mile radius), which makes section 3.8's
# reject-everything day unreachable. All three trajectories therefore wait
# SIM_DECLINE_WAIT_MIN minutes for the next request, so the comparison stays
# fair and a reject-everything day ends after at most 510 / 5 = 102 decisions.

SIM_SHIFT_HOURS <- 8
SIM_BREAK_OFFSET_HOURS <- 4
SIM_BREAK_MINUTES <- 30
SIM_FIRST_WINDOW_MIN <- 1
SIM_EXPAND_MIN <- 2
SIM_EXPAND_MILES <- 2
SIM_DECLINE_WAIT_MIN <- 5
SIM_MAX_STEPS <- 5000L

# set.seed() only accepts a 32-bit integer: a whole-number seed of any size
# (the contract allows int64) is folded into that range once, at the same
# place for every trajectory, so replays stay byte-identical.
normalize_seed <- function(seed) {
  s <- suppressWarnings(as.numeric(seed))
  if (!is.finite(s)) s <- 0
  as.integer(abs(s) %% 2147483647)
}

# One-row model frame for a dataset row (mirrors predict_handler and
# sensitivity_base_frame).
policy_frame <- function(trip) {
  data.frame(
    PULocationID = as.character(trip$PULocationID),
    DOLocationID = as.character(trip$DOLocationID),
    hvfhs_license_num = trip$hvfhs_license_num,
    trip_miles = trip$trip_miles,
    driver_pay = trip$driver_pay,
    request_datetime = trip$request_datetime,
    trip_time = trip$trip_time,
    trip_id = as.numeric(trip$trip_id),
    performance_per_hour = NA_real_,
    percentile_75_performance = NA_real_,
    tips = trip$tips,
    stringsAsFactors = FALSE
  )
}

empty_decisions <- function() {
  data.frame(
    step = integer(),
    trip_id = numeric(),
    accepted = logical(),
    model_recommended = logical(),
    trip_miles = numeric(),
    trip_time = integer(),
    driver_pay = numeric(),
    tips = numeric(),
    pu_location_id = integer(),
    do_location_id = integer(),
    request_datetime = as.POSIXct(character(), tz = "UTC"),
    dropoff_datetime = as.POSIXct(character(), tz = "UTC"),
    stringsAsFactors = FALSE
  )
}

decision_row <- function(step, trip, accepted, model_recommended) {
  data.frame(
    step = as.integer(step),
    trip_id = as.numeric(trip$trip_id),
    accepted = isTRUE(accepted),
    model_recommended = model_recommended,
    trip_miles = as.numeric(trip$trip_miles),
    trip_time = as.integer(trip$trip_time),
    driver_pay = as.numeric(trip$driver_pay),
    tips = as.numeric(trip$tips),
    pu_location_id = as.integer(trip$PULocationID),
    do_location_id = as.integer(trip$DOLocationID),
    request_datetime = trip$request_datetime,
    dropoff_datetime = trip$request_datetime + as.integer(trip$trip_time),
    stringsAsFactors = FALSE
  )
}

# Runs the day. `recorded` (optional data.frame with at least trip_id and
# accepted, in step order) replays a user trajectory; the first offer with no
# recorded decision is returned as `pending` instead of being decided.
#
# Returns list(decisions, pending, ended, clock, position, taken_break).
# `on_step` (optional) is called with the decisions produced so far after
# every appended row: the create endpoint uses it to persist the policy
# trajectory while it is still being simulated, so a client polling /state
# watches the day being prepared instead of waiting on a silent request.
simulate_day <- function(seed, company_code, start_datetime, start_location_id,
                         mode = c("policy", "baseline", "user"),
                         recorded = NULL, on_step = NULL) {
  mode <- match.arg(mode)
  start_datetime <- as.POSIXct(start_datetime, tz = "UTC")

  # The day is reproducible from `seed`, but the caller's RNG must come back
  # unchanged: the create endpoint draws the resume code from it, and leaving
  # it parked after set.seed(<experiment seed>) would make the next code a
  # deterministic function of the previous day.
  had_seed <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old_seed <- if (had_seed) get(".Random.seed", envir = globalenv()) else NULL
  on.exit({
    if (had_seed) {
      assign(".Random.seed", old_seed, envir = globalenv())
    } else if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
      rm(".Random.seed", envir = globalenv())
    }
  }, add = TRUE)
  set.seed(normalize_seed(seed))

  n_rec <- if (is.null(recorded) || nrow(recorded) == 0L) 0L else nrow(recorded)
  rows <- list()
  step <- 0L
  pending <- NULL
  error <- NULL

  current_time <- start_datetime
  position <- as.integer(start_location_id)
  time_limit <- start_datetime + SIM_FIRST_WINDOW_MIN * 60
  dist_limit <- 1
  break_at <- start_datetime + SIM_BREAK_OFFSET_HOURS * 3600
  last_limit <- start_datetime + SIM_SHIFT_HOURS * 3600 + SIM_BREAK_MINUTES * 60
  taken_break <- FALSE

  while (as.numeric(current_time) < as.numeric(last_limit)) {
    if (step >= SIM_MAX_STEPS) {
      cat("simulate_day: step cap ", SIM_MAX_STEPS, " reached\n", file = stderr())
      break
    }
    if (!taken_break && current_time >= break_at) {
      taken_break <- TRUE
      current_time <- current_time + SIM_BREAK_MINUTES * 60
      time_limit <- current_time + SIM_FIRST_WINDOW_MIN * 60
      dist_limit <- 1
    }

    cands <- candidate_trips(
      position, company_code, current_time, time_limit, last_limit, dist_limit
    )
    if (is.null(cands)) break
    if (nrow(cands) == 0L) {
      if (dist_limit == 1) {
        current_time <- current_time + SIM_FIRST_WINDOW_MIN * 60
      } else {
        current_time <- current_time + SIM_EXPAND_MIN * 60
      }
      time_limit <- time_limit + SIM_EXPAND_MIN * 60
      dist_limit <- dist_limit + SIM_EXPAND_MILES
      next
    }

    pick <- if (mode == "baseline") 1L else sample.int(nrow(cands), 1L)
    trip <- cands[pick, , drop = FALSE]

    if (mode == "policy") {
      probability <- policy_probability(policy_frame(trip))
      if (is.null(probability) || length(probability) != 1L || is.na(probability)) {
        error <- "model_unavailable"
        break
      }
      accept <- probability > policy_threshold
      recommended <- accept
    } else if (mode == "baseline") {
      accept <- TRUE
      recommended <- NA # batched after the loop (one predict for the day)
    } else {
      next_step <- step + 1L
      if (next_step > n_rec) {
        pending <- trip
        break
      }
      if (as.numeric(recorded$trip_id[[next_step]]) != as.numeric(trip$trip_id)) {
        cat(
          "simulate_day: replay divergence at step ", next_step,
          " (stored ", recorded$trip_id[[next_step]],
          ", replay ", trip$trip_id, ")\n",
          file = stderr()
        )
        break
      }
      accept <- isTRUE(as.logical(recorded$accepted[[next_step]]))
      recommended <- if ("model_recommended" %in% names(recorded)) {
        recorded$model_recommended[[next_step]]
      } else {
        NA
      }
    }

    step <- step + 1L
    rows[[step]] <- decision_row(step, trip, accept, recommended)
    if (!is.null(on_step)) on_step(do.call(rbind, rows))

    if (accept) {
      current_time <- trip$request_datetime + as.integer(trip$trip_time)
      position <- as.integer(trip$DOLocationID)
      time_limit <- current_time + SIM_FIRST_WINDOW_MIN * 60
      dist_limit <- 1
    } else {
      current_time <- trip$request_datetime + SIM_DECLINE_WAIT_MIN * 60
      if (current_time > time_limit) {
        # The decline penalty can push the clock past the open window. Both
        # branches then advance together, so the window would stay inverted
        # until the shift limit (no offers, no decisions): restart the search
        # from the new clock instead, exactly like the break does.
        time_limit <- current_time + SIM_FIRST_WINDOW_MIN * 60
        dist_limit <- 1
      }
    }
  }

  decisions <- if (length(rows) == 0L) empty_decisions() else do.call(rbind, rows)
  if (mode == "baseline" && nrow(decisions) > 0L && is.null(error)) {
    probabilities <- policy_probability(policy_frame_rows(decisions, company_code))
    if (is.null(probabilities) || length(probabilities) != nrow(decisions)) {
      error <- "model_unavailable"
    } else {
      decisions$model_recommended <- probabilities > policy_threshold
    }
  }

  list(
    decisions = decisions,
    pending = pending,
    ended = is.null(pending),
    clock = current_time,
    position = position,
    taken_break = taken_break,
    error = error
  )
}

# Model frame for a block of stored decisions (batched baseline
# recommendations); the company is a day-level constant, not stored per row.
policy_frame_rows <- function(decisions, company_code) {
  data.frame(
    PULocationID = as.character(decisions$pu_location_id),
    DOLocationID = as.character(decisions$do_location_id),
    hvfhs_license_num = company_code,
    trip_miles = decisions$trip_miles,
    driver_pay = decisions$driver_pay,
    request_datetime = decisions$request_datetime,
    trip_time = decisions$trip_time,
    trip_id = decisions$trip_id,
    performance_per_hour = NA_real_,
    percentile_75_performance = NA_real_,
    tips = decisions$tips,
    stringsAsFactors = FALSE
  )
}
