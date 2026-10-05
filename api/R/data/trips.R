# Trip dataset and zone lookup, loaded once at startup (phase 2, section 5.5).
#
#   NycTrips2024_sample_week.parquet -> trip_id (unique, sorted column) -> row
#   ZonesShapes.qs2                 -> LocationID -> "(id) borough - zone"
#
# trip_id is the dataset's own column (87,590,070..92,531,256 in the release),
# not the row number: lookups binary-search the sorted vector. The nine model
# columns of 4.87M rows take ~300MB of RAM, inside the 1.2GB RSS budget.

data_state <- new.env(parent = emptyenv())

data_dir <- function() Sys.getenv("TAXI_DATA_DIR", "/data")

trip_data_ready <- function() isTRUE(data_state$ready)

# Columns needed to rebuild the policy frame (mirrors predict_handler).
trip_columns <- function() {
  c(
    "trip_id", "hvfhs_license_num", "request_datetime", "PULocationID",
    "DOLocationID", "trip_miles", "trip_time", "tips", "driver_pay"
  )
}

load_trip_data <- function() {
  parquet <- file.path(data_dir(), "NycTrips2024_sample_week.parquet")
  zones_file <- file.path(data_dir(), "ZonesShapes.qs2")
  if (!file.exists(parquet) || !file.exists(zones_file)) {
    data_state$ready <- FALSE
    return(FALSE)
  }
  t0 <- proc.time()[["elapsed"]]
  trips <- as.data.frame(
    nanoparquet::read_parquet(parquet, col_select = trip_columns())
  )
  if (!inherits(trips$request_datetime, "POSIXct")) {
    trips$request_datetime <- as.POSIXct(
      trips$request_datetime, origin = "1970-01-01", tz = "UTC"
    )
  }
  tz <- attr(trips$request_datetime, "tzone")
  if (is.null(tz) || !nzchar(tz)) attr(trips$request_datetime, "tzone") <- "UTC"
  # trip_id must be sorted for the binary search in trip_row()
  if (is.unsorted(trips$trip_id, strictly = TRUE)) {
    trips <- trips[order(trips$trip_id), , drop = FALSE]
  }
  data_state$trips <- trips

  zones <- qs2::qs_read(zones_file)
  data_state$zones <- data.frame(
    LocationID = as.integer(zones$LocationID),
    borough = as.character(zones$borough),
    zone = as.character(zones$zone),
    stringsAsFactors = FALSE
  )
  data_state$ready <- TRUE
  cat(sprintf(
    "trip data: %s rows, %s zones (%.1fs, %d MB)\n",
    format(nrow(trips), big.mark = ","),
    nrow(data_state$zones),
    proc.time()[["elapsed"]] - t0,
    round(as.numeric(object.size(trips)) / 1024^2)
  ), file = stderr())
  TRUE
}

# One-row data.frame for the given trip_id, or NULL when it is not in the
# dataset (contract 404 for /sensitivity).
trip_row <- function(trip_id) {
  if (!trip_data_ready() || !is_number(trip_id)) return(NULL)
  tid <- data_state$trips$trip_id
  i <- findInterval(trip_id, tid)
  if (i < 1L || tid[i] != trip_id) return(NULL)
  data_state$trips[i, , drop = FALSE]
}

# Zone metadata (borough, name) for labels; NULL when the id is unknown
# (ids 264/265 have no geometry in ZonesShapes.qs2).
zone_info <- function(location_id) {
  if (!trip_data_ready()) return(NULL)
  i <- match(as.integer(location_id), data_state$zones$LocationID)
  if (is.na(i)) return(NULL)
  data_state$zones[i, , drop = FALSE]
}

# Zone ids the policy may suggest (section 5.5 ports the prototype's
# Manhattan/Brooklyn/Queens subset), always excluding the current zone.
sensitivity_zone_candidates <- function(current_id) {
  z <- data_state$zones
  keep <- z$borough %in% c("Manhattan", "Brooklyn", "Queens")
  setdiff(z$LocationID[keep], as.integer(current_id))
}
