# Sensitivity grids (phase 2, section 5.5): a plotting-free port of the
# prototype's select_zone_with_high_change() and of the calculation half of
# plot_decision_boundary() (NycTaxi investigation-phases/12-shiny-app.qmd).
# The plotting half lives in the UI as plot_sensitivity_girafe() (phase 6).
#
# Output: three grid_len x grid_len frames (trip_time_sec x driver_pay x prob)
# for the original zones, an alternative pickup zone and an alternative
# drop-off zone, plus the display metadata of the contract's SensitivityResponse.

sensitivity_threshold <- 0.9

zone_label <- function(location_id) {
  info <- zone_info(location_id)
  if (is.null(info)) return(paste0("(", location_id, ")"))
  sprintf("(%s) %s - %s", info$LocationID, info$borough, info$zone)
}

# One-row policy frame from a dataset row; same layout as predict_handler.
sensitivity_base_frame <- function(trip) {
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

# Port of select_zone_with_high_change(): among the candidate zones, the one
# whose substitution moves P(high-value) the most for this trip. The original
# built nrow(zones)-1 rows and predicted once; same here (candidates already
# exclude the current zone).
select_zone_with_high_change <- function(base_frame, candidates, var_to_change) {
  stopifnot(nrow(base_frame) == 1L, length(candidates) > 0L)
  others <- base_frame[rep(1L, length(candidates)), , drop = FALSE]
  others[[var_to_change]] <- as.character(candidates)
  original_prob <- policy_probability(base_frame)
  other_prob <- policy_probability(others)
  as.integer(candidates[[which.max(abs(original_prob - other_prob))]])
}

# Port of the grid computation of plot_decision_boundary(): vary trip_time
# and driver_pay over a grid_len x grid_len grid, everything else fixed,
# and predict P(high-value) for the original, pickup-changed and
# drop-off-changed versions of the trip. Returns the three data.frames.
compute_decision_grid <- function(base_frame, pu_zone, do_zone, grid_len) {
  stopifnot(nrow(base_frame) == 1L, grid_len >= 2L)
  # Same ranges as the prototype: full axes, extended when the trip exceeds
  # the plotting window.
  range_x <- c(0, max(2500, base_frame$trip_time))
  range_y <- c(0, max(65, base_frame$driver_pay))
  times <- round(seq(range_x[1], range_x[2], length.out = grid_len))
  pays <- seq(range_y[1], range_y[2], length.out = grid_len)

  build_rows <- function(pu, do) {
    n <- grid_len * grid_len
    rows <- base_frame[rep(1L, n), , drop = FALSE]
    rows$trip_time <- rep(times, each = grid_len)
    rows$driver_pay <- rep(pays, times = grid_len)
    rows$PULocationID <- as.character(pu)
    rows$DOLocationID <- as.character(do)
    rows
  }

  frame <- function(pu, do) {
    rows <- build_rows(pu, do)
    probs <- policy_probability(rows)
    data.frame(
      trip_time_sec = as.integer(rows$trip_time),
      driver_pay = rows$driver_pay,
      prob = probs,
      stringsAsFactors = FALSE
    )
  }

  base_pu <- as.integer(base_frame$PULocationID)
  base_do <- as.integer(base_frame$DOLocationID)
  list(
    original = frame(base_pu, base_do),
    pu = frame(pu_zone, base_do),
    do = frame(base_pu, do_zone)
  )
}
