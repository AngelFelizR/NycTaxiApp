# Planted trip week + policy mocks shared by the phase-3 simulation tests
# (test-simulate.R, test-experiments.R). Small, deterministic and fast: the
# real parquet is never touched, so these tests need neither /data nor a
# model file.

# A 1-mile square ring in the zones' planar CRS: enough for
# build_search_index() to derive centroid distances (all three zones share the
# same footprint, so every pickup is inside the initial 1-mile window).
sim_zone_ring <- function() {
  matrix(c(0, 1, 1, 0, 0, 0, 1, 1), ncol = 2) * 5280
}

# 1201 trips every 30 seconds (08:00-18:00), all Lyft, every 5th one WAV.
# Denser than the real week on purpose: the search window opens at one
# minute, so a 30-second grid always puts two offers on the table and the
# seed is what breaks the tie between them.
plant_sim_data <- function() {
  zones <- data.frame(
    LocationID = c(61L, 161L, 230L),
    borough = c("Brooklyn", "Manhattan", "Manhattan"),
    zone = c("Crown Heights North", "Midtown Center", "Times Sq/Theatre District"),
    stringsAsFactors = FALSE
  )
  zones_geo <- zones
  zones_geo$geometry <- list(sim_zone_ring(), sim_zone_ring(), sim_zone_ring())

  grid <- seq(
    as.POSIXct("2024-05-12 08:00:00", tz = "UTC"),
    as.POSIXct("2024-05-12 18:00:00", tz = "UTC"),
    by = "30 sec"
  )
  n <- length(grid)
  data_state$trips <- data.frame(
    trip_id = seq_len(n),
    hvfhs_license_num = "HV0005",
    request_datetime = grid,
    PULocationID = rep(c(61L, 161L, 230L), length.out = n),
    DOLocationID = rep(c(161L, 230L, 61L), length.out = n),
    trip_miles = 3,
    trip_time = 600,
    tips = 1,
    driver_pay = 20,
    wav_match_flag = ifelse(seq_len(n) %% 5 == 0, "Y", "N"),
    stringsAsFactors = FALSE
  )
  data_state$zones <- zones
  data_state$ready <- TRUE
  build_search_index(zones_geo)
  invisible(TRUE)
}

unplant_sim_data <- function() {
  data_state$ready <- FALSE
  invisible(TRUE)
}

# First start the planted week still leaves room for a whole 8h30 shift.
sim_start_datetime <- function() {
  as.POSIXct("2024-05-12 08:00:00", tz = "UTC")
}

# Deterministic stand-in for the fitted policy (probability is driven by pay).
sim_policy_probability <- function(frame) rep(0.95, nrow(frame))

with_accept_all_policy <- function(code) {
  orig <- get("policy_probability", envir = globalenv())
  assign("policy_probability", sim_policy_probability, envir = globalenv())
  on.exit(assign("policy_probability", orig, envir = globalenv()), add = TRUE)
  force(code)
}
