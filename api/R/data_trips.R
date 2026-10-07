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

# Columns needed to rebuild the policy frame (mirrors predict_handler) plus
# wav_match_flag, which the simulation (phase 3) uses for the WAV rule.
trip_columns <- function() {
  c(
    "trip_id", "hvfhs_license_num", "request_datetime", "PULocationID",
    "DOLocationID", "trip_miles", "trip_time", "tips", "driver_pay",
    "wav_match_flag"
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
  build_search_index(zones)
  cat(sprintf(
    "trip data: %s rows, %s zones (%.1fs, %d MB)\n",
    format(nrow(trips), big.mark = ","),
    nrow(data_state$zones),
    proc.time()[["elapsed"]] - t0,
    round(as.numeric(object.size(trips)) / 1024^2)
  ), file = stderr())
  TRUE
}

# ---- search index (phase 3) ------------------------------------------------
#
# Two structures that turn the prototype's per-iteration SQL (section 3) into
# an in-memory range scan:
#
#   * req_order / req_sorted: request_datetime order + its sorted values, so a
#     search window is a binary search (findInterval) followed by an integer
#     gather. ~58 MB for 4.87M rows, inside the 1.2 GB RSS budget.
#   * mean_miles: mean trip_miles per (PULocationID, DOLocationID) -- the
#     prototype's PointMeanDistance table -- with a zone-centroid fallback for
#     the 16k pairs the week never observed (a driver must not get stuck when
#     the dataset has no sample for a pair, e.g. dropping off at EWR).
#
# Centroids come from ZonesShapes.qs2, whose CRS is NAD83 / New York Long
# Island (ftUS): plain planar distance in feet converted to miles, then scaled
# by the median observed/centroid ratio so the fallback matches road miles.
# sf is not in the API pin, so the shoelace centroid is computed here in base
# R (measured: 65 ms for the 263 zones).

N_ZONES <- 265L

build_search_index <- function(zones_sf) {
  trips <- data_state$trips
  o <- order(trips$request_datetime)
  data_state$req_order <- as.integer(o)
  data_state$req_sorted <- as.numeric(trips$request_datetime[o])

  data_state$zone_ok <- rep(FALSE, N_ZONES + 1L)
  ids <- data_state$zones$LocationID
  data_state$zone_ok[ids[ids >= 1L & ids <= N_ZONES]] <- TRUE

  data_state$mean_miles <- build_mean_miles(trips, zones_sf)
  invisible(TRUE)
}

# Mean road miles per zone pair from the dataset, completed with scaled
# centroid distances where the week has no sample.
build_mean_miles <- function(trips, zones_sf) {
  x <- trips$trip_miles
  key <- (as.integer(trips$PULocationID) - 1L) * N_ZONES +
    as.integer(trips$DOLocationID)
  sums <- rowsum(x, key, na.rm = TRUE)
  cnts <- rowsum(as.numeric(!is.na(x)), key)
  g <- as.numeric(rownames(sums))
  pu_g <- (g - 1) %/% N_ZONES + 1
  do_g <- g - (pu_g - 1) * N_ZONES

  mat <- matrix(NA_real_, N_ZONES + 1L, N_ZONES + 1L)
  mat[cbind(pu_g, do_g)] <- sums[, 1L] / pmax(cnts[, 1L], 1)
  rm(sums, cnts, g, pu_g, do_g, key, x)

  cen <- zone_centroids(zones_sf)
  if (is.null(cen)) {
    message("search index: no zone centroids; pairs without samples stay empty")
    return(mat)
  }
  xs <- cen$x
  ys <- cen$y
  dm <- matrix(NA_real_, N_ZONES + 1L, N_ZONES + 1L)
  dm[cen$id, cen$id] <- sqrt(outer(xs, xs, "-")^2 + outer(ys, ys, "-")^2) / 5280

  observed <- !is.na(mat) & !is.na(dm) & dm > 0.05
  ratio <- if (any(observed)) median(mat[observed] / dm[observed]) else 1
  if (!is.finite(ratio) || ratio <= 0) ratio <- 1
  missing <- is.na(mat) & !is.na(dm)
  mat[missing] <- dm[missing] * ratio
  attr(mat, "centroid_scale") <- ratio
  mat
}

# Zone centroids in the geometry's own planar CRS (NAD83 / New York Long
# Island, US survey feet): area-weighted shoelace centroid per ring, computed
# around a local origin so the 1e6-magnitude eastings do not cancel. Returns
# NULL when the geometry column is missing or unusable.
zone_centroids <- function(zones_sf) {
  ids <- as.integer(zones_sf$LocationID)
  geom <- tryCatch(zones_sf$geometry, error = function(e) NULL)
  if (is.null(geom) || length(geom) != length(ids)) return(NULL)
  origin <- c(990000, 200000)
  xy <- t(vapply(geom, function(g) polygon_centroid(g, origin), numeric(2)))
  ok <- which(is.finite(xy[, 1]) & is.finite(xy[, 2]))
  ids2 <- ids[ok]
  ok <- ok[ids2 >= 1L & ids2 <= N_ZONES]
  if (length(ok) == 0L) return(NULL)
  list(id = ids[ok], x = xy[ok, 1], y = xy[ok, 2])
}

polygon_centroid <- function(mp, origin) {
  ox <- origin[[1]]
  oy <- origin[[2]]
  cx <- 0
  cy <- 0
  aw <- 0
  vx <- 0
  vy <- 0
  nv <- 0
  visit_ring <- function(ring) {
    if (!is.matrix(ring) || nrow(ring) < 3L || ncol(ring) < 2L) return(invisible(NULL))
    x <- ring[, 1] - ox
    y <- ring[, 2] - oy
    x2 <- c(x[-1], x[1])
    y2 <- c(y[-1], y[1])
    cr <- x * y2 - x2 * y
    ra <- sum(cr) / 2
    if (ra != 0) {
      rgx <- sum((x + x2) * cr) / (6 * ra)
      rgy <- sum((y + y2) * cr) / (6 * ra)
      w <- abs(ra)
      cx <<- cx + rgx * w
      cy <<- cy + rgy * w
      aw <<- aw + w
    }
    vx <<- vx + sum(x)
    vy <<- vy + sum(y)
    nv <<- nv + length(x)
    invisible(NULL)
  }
  if (is.matrix(mp)) {
    visit_ring(mp)
  } else if (is.list(mp)) {
    for (poly in mp) {
      if (is.matrix(poly)) {
        visit_ring(poly)
      } else if (is.list(poly)) {
        for (ring in poly) visit_ring(ring)
      }
    }
  }
  if (aw > 0) return(c(ox + cx / aw, oy + cy / aw))
  if (nv > 0) return(c(ox + vx / nv, oy + vy / nv))
  c(NA_real_, NA_real_)
}

# Candidate trips for one search step (prototype SQL of section 3): request
# inside [current_time, min(time_limit, last_limit)], same company, WAV rule,
# pickup within dist_limit miles of the current position, drop-off a zone the
# driver could work from. Returned ordered by request_datetime (the window is
# a contiguous slice of the time index), which is what defines the baseline's
# "first trip found".
candidate_trips <- function(pos, company_code, current_time, time_limit,
                            last_limit, dist_limit, wav_codes = "N") {
  empty <- function() data_state$trips[0L, , drop = FALSE]
  if (!trip_data_ready()) return(NULL)
  if (!is_number(pos) || pos < 1 || pos > N_ZONES) return(empty())
  ts <- data_state$req_sorted
  hi_bound <- min(as.numeric(time_limit), as.numeric(last_limit))
  lo <- findInterval(as.numeric(current_time), ts, left.open = TRUE) + 1L
  hi <- findInterval(hi_bound, ts)
  if (lo > hi) return(empty())
  idx <- data_state$req_order[lo:hi]
  sub <- data_state$trips[idx, , drop = FALSE]
  keep <- sub$hvfhs_license_num == company_code &
    (sub$wav_match_flag %in% wav_codes) &
    data_state$zone_ok[as.integer(sub$DOLocationID)]
  miles <- data_state$mean_miles[as.integer(pos), as.integer(sub$PULocationID)]
  keep <- !is.na(keep) & keep & !is.na(miles) & miles <= dist_limit
  sub[keep, , drop = FALSE]
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

# Display name used by the game state ("Queens - Saint Albans"); keeps the
# "(id)" fallback of zone_label() for ids without geometry.
zone_display <- function(location_id) {
  info <- zone_info(location_id)
  if (is.null(info)) return(paste0("(", location_id, ")"))
  sprintf("%s - %s", info$borough, info$zone)
}

# First and last request_datetime of the loaded week: POST /experiments
# rejects a shift that would run outside the simulated data (422).
trip_data_range <- function() {
  if (!trip_data_ready() || length(data_state$req_sorted) == 0L) return(NULL)
  r <- range(data_state$req_sorted)
  as.POSIXct(r, origin = "1970-01-01", tz = "UTC")
}

# Zone ids the policy may suggest (section 5.5 ports the prototype's
# Manhattan/Brooklyn/Queens subset), always excluding the current zone.
sensitivity_zone_candidates <- function(current_id) {
  z <- data_state$zones
  keep <- z$borough %in% c("Manhattan", "Brooklyn", "Queens")
  setdiff(z$LocationID[keep], as.integer(current_id))
}
