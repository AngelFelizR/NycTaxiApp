# Static data preloaded at startup (master doc 6.1.3): companies, zones and
# defaults are read once from the read-only data volume, never from GitHub or
# from the network while the app runs.

constants_state <- new.env(parent = emptyenv())

# Dev (host/container) keeps the data in DATA_DIR; production mounts the same
# files read-only at /srv/nyctaxi/data (4.5). The dev container mounts them at
# /data, and the .env value is a *host* path that does not exist inside it, so
# the first candidate that actually exists wins.
# Where the read-only data volume can be (6.1.3: everything static is
# preloaded from it, so the app never waits on the network). Exposed as its own
# function because the list *is* the contract between this code and whoever
# mounts the volume -- §8.3 mounts it at /app/data, §6.1.3 names
# /srv/nyctaxi/data, and the dev compose mounts it at /data. Missing one of
# them means an empty map in production with nothing in the logs to say why.
app_data_candidates <- function() {
  c(
    Sys.getenv("DATA_DIR", ""),
    "/data",
    "/app/data",
    file.path(path.expand("~"), "nyctaxi", "data"),
    "/srv/nyctaxi/data"
  )
}

app_data_dir <- function() {
  cands <- app_data_candidates()
  cands <- cands[nzchar(cands)]
  hit <- cands[file.exists(cands)]
  if (length(hit) > 0) hit[1] else cands[1]
}

# Fill unset variables from a KEY=VALUE file. Never overrides what the
# environment already carries (Docker/ShinyProxy inject the real values in
# production), and never fails when the file is absent -- production has none.
load_env_file <- function(path) {
  if (!file.exists(path)) return(invisible(FALSE))
  lines <- trimws(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "#")]
  for (line in lines) {
    if (!grepl("=", line, fixed = TRUE)) next
    key <- trimws(sub("=.*$", "", line))
    value <- trimws(sub("^[^=]*=", "", line))
    if (nzchar(key) && !nzchar(Sys.getenv(key))) {
      do.call(Sys.setenv, stats::setNames(list(value), key))
    }
  }
  invisible(TRUE)
}

COMPANIES <- c("Lyft", "Uber")

# The sample week shipped in DATA_DIR runs 2024-05-12 .. 2024-05-19, so the
# default start sits inside it; zone 61 (Crown Heights North) is the same one
# the contract uses in its examples.
DEFAULT_START_DATETIME <- "2024-05-12T00:00:00Z"
DEFAULT_LOCATION_ID <- 61L

# Zones come from ZonesShapes.qs2 (the very file the API reads): sf with
# LocationID, borough, zone and geometry, 263 rows. Loaded lazily so unit
# tests without the volume still run, and cached for the life of the process.
zones_sf <- function() {
  if (!is.null(constants_state$zones)) return(constants_state$zones)
  path <- file.path(app_data_dir(), "ZonesShapes.qs2")
  constants_state$zones <- if (file.exists(path)) {
    tryCatch(qs2::qs_read(path), error = function(e) NULL)
  } else {
    NULL
  }
  constants_state$zones
}

# Choices for the selectize: id -> "borough - zone" (the label the API uses
# too, e.g. "Brooklyn - Crown Heights North"). Named vector keeps the id.
#
# The columns are read straight off the sf object: sf::st_drop_geometry() is
# only a data.frame() wrapper, but calling it pulls the whole sf namespace in
# (~1 s) and app_options() runs while the app starts up. The geometry stays
# lazy until a map actually renders.
zone_choices <- function() {
  z <- zones_sf()
  if (is.null(z)) return(stats::setNames(character(0), character(0)))
  labels <- paste(z$borough, z$zone, sep = " - ")
  stats::setNames(as.integer(z$LocationID), labels)
}

# Geometry for the Leaflet map, in WGS84, keyed by LocationID. Zones without
# geometry (264/265) are simply not clickable on the map; they are not valid
# starting zones either. The transform is cached: it costs ~0.16 s and both
# the Setup map and every offer's route need the same object.
zones_map_data <- function() {
  if (!is.null(constants_state$zones_wgs84)) return(constants_state$zones_wgs84)
  z <- zones_sf()
  if (is.null(z)) return(NULL)
  if (is.na(sf::st_crs(z))) sf::st_crs(z) <- 2263  # NAD83 / New York Long Island
  constants_state$zones_wgs84 <- sf::st_transform(z, 4326)
}

# The setup dropdowns. Section 6.1.3: companies, zones and defaults are
# preloaded here from the read-only volume -- there is no /options endpoint in
# contract/openapi.yaml, and fetching them would tie the first paint to the
# API being up.
app_options <- function() {
  list(
    companies = COMPANIES,
    zones = zone_choices(),
    default_start_dt = DEFAULT_START_DATETIME,
    default_location_id = DEFAULT_LOCATION_ID
  )
}

# Choices for the two sensitivity selectors: "-" keeps the original zone
# (zone_or_null() maps it back to NULL for the API call).
zone_select_choices <- function() {
  ch <- zone_choices()
  if (length(ch) == 0) return(c("-" = "-"))
  c("-" = "-", ch)
}
