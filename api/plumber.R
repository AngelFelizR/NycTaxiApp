#!/usr/bin/env Rscript
# NYC Taxi API -- plumber2 entrypoint (phase 1, section 5.1 of the master doc).
#
# Models are loaded in this process before plumber2 starts (section 5.9):
# the policy goes through mori::share() and is dropped from the heap, the
# tree and the valid-hours lookup stay as plain objects. Run it with:
#
#   nix-shell api/default.dev.nix --run "Rscript api/plumber.R"

args_all <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- if (length(args_all) > 0) {
  sub("^--file=", "", args_all[1])
} else {
  file.path("api", "plumber.R")
}
root <- normalizePath(file.path(dirname(script_path), ".."))

source(file.path(root, "api", "R", "utils.R"))
load_dotenv(file.path(root, ".env"))

suppressPackageStartupMessages({
  library(plumber2)
  library(qs2)
  library(mori)
  library(jsonlite)
  library(lubridate)
  library(data.table)
  library(digest)
  library(pool)
  library(DBI)
  library(RPostgres)
  # predict() needs the full modelling stack, and the baked recipes resolve
  # their quosures through the search path (sanitised envs sit on
  # globalenv()), so every package the steps use must be attached here.
  library(workflows)
  library(parsnip)
  library(recipes)
  library(themis)
  library(embed)
  library(timeDate)
  library(tailor)
  library(ggplot2)
  # Trip dataset (phase 2) and the Redis cache
  library(nanoparquet)
  library(redux)
})

for (rel in c(
  "R/db/pool.R",
  "R/db/redis.R",
  "R/data/trips.R",
  "R/ml/load_model.R",
  "R/ml/perf.R",
  "R/ml/predict.R",
  "R/ml/recommend.R",
  "R/ml/sensitivity.R",
  "R/middleware/internal_auth.R",
  "R/middleware/cors.R",
  "R/endpoints/health.R",
  "R/endpoints/predict.R",
  "R/endpoints/recommend_start.R",
  "R/endpoints/validate_trip_start.R",
  "R/endpoints/sensitivity.R",
  "R/endpoints/not_found.R"
)) {
  source(file.path(root, "api", rel))
}
source(file.path(root, "api", "R", "ml", "steps", "step_join_geospatial_features.R"))

# Memoize timeDate holiday calendars and swap in the faster bake methods
# for step_impute_median / step_rename (phase-1 latency budget): exact same
# outputs, avoids ~115ms of calendar recomputation and ~35ms of tibble
# machinery per predict.
n_speedups <- install_time_speedups()
cat("time speedups installed:", n_speedups, "\n", file = stderr())
n_bake_speedups <- install_bake_speedups()
cat("bake speedups installed:", n_bake_speedups, "\n", file = stderr())

model_error <- NULL
tryCatch(
  load_models(),
  error = function(e) {
    model_error <<- conditionMessage(e)
    message("model loading failed: ", model_error)
  }
)
model_state$pool <- create_db_pool()

# Phase 2: trip dataset + zone shapes (~300MB) and a Redis ping, both logged.
# A missing /data mount or a down Redis only disables /sensitivity caching;
# the API still starts (the handler answers 503/uncached accordingly).
tryCatch(
  if (!load_trip_data()) {
    message("trip data unavailable under ", data_dir(),
            " (/sensitivity will answer 503)")
  },
  error = function(e) message("trip data loading failed: ", conditionMessage(e))
)
cat("redis:", if (redis_available()) "ok" else "unavailable", "\n",
    file = stderr())

# Warm-up: the first request of a fresh process pays for mapping the shared
# policy segment and for the lazy per-process caches (holiday calendars,
# US holiday calendars in the mutate quosures, first bake of every step).
# Run one synthetic inference per model now so the phase-1 criterion
# "curl responds in <100ms with the models loaded" (section 14) holds from
# the very first request instead of costing ~1s on request #1.
t_warm <- proc.time()[["elapsed"]]
tryCatch({
  warm <- data.frame(
    PULocationID = "61", DOLocationID = "230",
    hvfhs_license_num = "HV0003",
    trip_miles = 2.5, driver_pay = 28.5,
    request_datetime = as.POSIXct("2025-01-06 08:30:00", tz = "UTC"),
    trip_time = 1500, trip_id = NA_real_,
    performance_per_hour = NA_real_,
    percentile_75_performance = NA_real_,
    stringsAsFactors = FALSE
  )
  invisible(policy_probability(warm))
  invisible(start_is_high_value(
    "Uber", as.POSIXct("2025-01-06 08:30:00", tz = "UTC"), 61L
  ))
  invisible(next_valid_start(
    model_state$valid_hours,
    as.POSIXct("2025-01-06 08:30:00", tz = "UTC")
  ))
}, error = function(e) message("warmup failed: ", conditionMessage(e)))
cat("warmup:", round(proc.time()[["elapsed"]] - t_warm, 2), "s\n",
  file = stderr())

if (!nzchar(Sys.getenv("API_INTERNAL_KEY"))) {
  message("WARNING: API_INTERNAL_KEY is empty; every request will be rejected with 403")
}

host <- Sys.getenv("API_HOST", "0.0.0.0")
port <- as.integer(Sys.getenv("API_PORT", "8000"))
js <- json_serializers()

api <- plumber2::api(host = host, port = port)
# NOTE on plugin order: firesafety::CORS$on_attach creates its own
# header/request RouteStacks when they do not exist yet, bypassing plumber2's
# lazy fields -- a later api_get/api_any_header then aborts with
# "The request_routr/header_routr plugin is already loaded". So: register
# api_any_header first (it materialises the header router properly), then all
# routes (materialises the request router), and cors LAST so it reuses them.
api <- plumber2::api_any_header(
  api, "/*", internal_auth_header,
  serializers = js
)
api <- plumber2::api_get(api, "/health", health_handler, serializers = js)
# Identity parsers: plumber2 only reads the body when parsers are set AND the
# handler declares a `body` formal; JSON is validated manually in the
# handlers so malformed payloads get the contract's 400 instead of a 500.
pj <- raw_json_parsers()
api <- plumber2::api_post(api, "/predict", predict_handler, serializers = js, parsers = pj)
api <- plumber2::api_post(
  api, "/recommend-start", recommend_start_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_post(
  api, "/validate-trip-start", validate_trip_start_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_post(
  api, "/sensitivity", sensitivity_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_any(api, "/*", not_found_handler, serializers = js)
api <- apply_cors(api)

rss_kb <- as.integer(sub(".*:\\s+([0-9]+) kB.*", "\\1",
  grep("VmRSS", readLines("/proc/self/status"), value = TRUE)[1]))
message(
  "NYC Taxi API listening on ", host, ":", port,
  " | R ", getRversion(),
  " | models: ", paste(names(Filter(identity, models_status())), collapse = ","),
  if (!is.null(model_error)) paste0(" (load error: ", model_error, ")") else "",
  " | RSS ", round(rss_kb / 1024), " MB"
)

plumber2::api_run(api, host = host, port = port, block = TRUE, silent = FALSE)
