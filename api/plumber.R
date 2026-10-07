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

# POST /experiments forks a child to compute the two model trajectories
# (R/endpoints/experiments.R). fork() only copies the calling thread, so any
# worker thread the parent owns becomes a lock nobody holds: OpenMP builds its
# thread pool at the first parallel region (warmup, first predict) and the
# child then deadlocks in futex_wait with no CPU at all. One thread per
# library keeps the parent fork-safe; the batches here are small, so nothing
# is lost.
#
# libgomp is already loaded when R starts and reads OMP_NUM_THREADS in its
# constructor, so this has to be exported by the shell (api/default.dev.nix
# and the root default.nix do it) rather than set here. What follows is a
# best effort for the libraries that read it lazily, plus a loud warning when
# the shell got it wrong: Sys.setenv() cannot repair libgomp after the fact.
omp_at_start <- Sys.getenv("OMP_NUM_THREADS")
if (!identical(omp_at_start, "1")) {
  cat(
    "WARNING: OMP_NUM_THREADS='", omp_at_start, "' when R started, and ",
    "libgomp already read it.\n",
    "         POST /experiments forks a child and can deadlock (futex_wait). ",
    "Use nix-shell\n",
    "         (api/default.dev.nix) or export OMP_NUM_THREADS=1 before ",
    "starting R.\n",
    sep = "", file = stderr()
  )
}
Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1"
)

# Load taxiapi. The image installs it (api/Dockerfile runs R CMD INSTALL), so
# production runs a package built from the source that is in the image; a
# development shell has no installed copy and loads the source instead. The
# two are the same files, and pkgload never reaches an image because the
# installed branch is the only one that runs there.
if (requireNamespace("taxiapi", quietly = TRUE)) {
  suppressPackageStartupMessages(library(taxiapi))
} else {
  pkgload::load_all(file.path(root, "api"), export_all = TRUE,
                    helpers = FALSE, attach_testthat = FALSE, quiet = TRUE)
}
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
# Phase 3: apply api/migrations/*.sql on boot (idempotent; a fresh database
# comes up without a manual step). model_state$repo_root is what resolves the
# migration directory from the tests too.
model_state$repo_root <- root
model_state$pool <- create_db_pool()
tryCatch(
  if (!ensure_schema(model_state$pool)) {
    message("migrations: schema not ready (experiments answer 503 until fixed)")
  },
  error = function(e) message("migrations failed: ", conditionMessage(e))
)

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
# request_context wraps internal_auth_header: plumber2 aborts if the header
# router is materialised twice, so the per-request log context (section 11:
# correlation_id, ip_hash, start time) has to ride along with auth rather than
# register a second catch-all.
api <- plumber2::api_any_header(
  api, "/*", request_context,
  serializers = js
)
# Section 11: one JSON line per request with method, path, status,
# duration_ms, correlation_id and ip_hash. Conditions keep the default logger.
# logger = NULL keeps whatever is installed, which by default is
# logger_null() -- i.e. nothing is written at all. Console for conditions,
# JSON for the per-request line.
# Section 11: the JSON line is produced by `access_logger` (see
# middleware/request_context.R for why it cannot be a format string), and
# `access_log_format` is only a token so the "request" event still fires.
api <- plumber2::api_logger(
  api,
  logger = access_logger,
  access_log_format = access_log_format
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
# Phase 3: experiments, share data, waitlist, metrics (sections 5.2-5.8).
# GET routes without a body take no parsers; POST routes that read a payload
# declare `body` and get the identity JSON parser like the others.
api <- plumber2::api_post(
  api, "/experiments", create_experiment_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_get(api, "/experiments/<id>", get_experiment_handler, serializers = js)
api <- plumber2::api_get(api, "/experiments/<id>/state", get_state_handler, serializers = js)
api <- plumber2::api_post(
  api, "/experiments/<id>/decisions", create_decision_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_post(api, "/experiments/<id>/finish", finish_experiment_handler, serializers = js)
api <- plumber2::api_post(
  api, "/experiments/<id>/feedback", feedback_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_post(api, "/experiments/<id>/abandon", abandon_experiment_handler, serializers = js)
api <- plumber2::api_post(
  api, "/experiments/<id>/share-email", share_email_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_get(api, "/share-data/<token>", share_data_handler, serializers = js)
api <- plumber2::api_post(
  api, "/waitlist", waitlist_handler,
  serializers = js, parsers = pj
)
api <- plumber2::api_get(api, "/metrics", metrics_handler, serializers = js)
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
