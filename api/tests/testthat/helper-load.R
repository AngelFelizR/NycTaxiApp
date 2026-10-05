# Load the code under test (api/ is not an installed package, so R/ is
# sourced by hand, mirroring app/tests/testthat/helper-load.R). testthat runs
# with the working directory set to tests/testthat.
#
# Same rule as plumber.R and the nix shells: libgomp reads OMP_NUM_THREADS
# when R starts, and a fork after it has built its thread pool deadlocks the
# child. The shells export it; this is a best effort for libraries that read
# the variable lazily, and `.omp_at_start` remembers what the shell actually
# did so test-experiments-async.R can skip its fork when it was not exported.
.omp_at_start <- Sys.getenv("OMP_NUM_THREADS")
Sys.setenv(
  OMP_NUM_THREADS = "1",
  OPENBLAS_NUM_THREADS = "1",
  VECLIB_MAXIMUM_THREADS = "1"
)
suppressPackageStartupMessages({
  library(jsonlite)
  library(lubridate)
  library(data.table)
  library(digest)
  library(recipes)
  library(workflows)
  library(parsnip)
  library(plumber2)
})
api_dir <- normalizePath(file.path("..", ".."))
source(file.path(api_dir, "R", "utils.R"))
# Same .env as plumber.R: inside the dev container it carries POSTGRES_*,
# REDIS_*, API_INTERNAL_KEY and IP_HASH_SALT (the container injects no env of
# its own), so the phase-3 tests hit the real Postgres and Redis of the root
# compose. TAXI_DATA_DIR/TAXI_MODELS_DIR are not in .env, so they keep their
# /data and /models defaults unless a test overrides them.
load_dotenv(file.path(api_dir, "..", ".env"))
# POST /experiments forks the trajectory computation by default; tests run it
# inline so assertions never race a background child. The async behaviour is
# covered by test-experiments-async.R, which flips this off per test.
Sys.setenv(API_EXPERIMENTS_SYNC = "1")
source(file.path(api_dir, "R", "db", "pool.R"))
source(file.path(api_dir, "R", "db", "redis.R"))
source(file.path(api_dir, "R", "db", "migrations.R"))
source(file.path(api_dir, "R", "db", "queries.R"))
source(file.path(api_dir, "R", "data", "trips.R"))
source(file.path(api_dir, "R", "ml", "load_model.R"))
source(file.path(api_dir, "R", "ml", "perf.R"))
source(file.path(api_dir, "R", "ml", "predict.R"))
source(file.path(api_dir, "R", "ml", "recommend.R"))
source(file.path(api_dir, "R", "ml", "sensitivity.R"))
source(file.path(api_dir, "R", "ml", "simulate.R"))
source(file.path(api_dir, "R", "ml", "outcome.R"))
source(file.path(api_dir, "R", "middleware", "internal_auth.R"))
source(file.path(api_dir, "R", "middleware", "client_ip.R"))
source(file.path(api_dir, "R", "middleware", "rate_limit.R"))
source(file.path(api_dir, "R", "endpoints", "health.R"))
source(file.path(api_dir, "R", "endpoints", "predict.R"))
source(file.path(api_dir, "R", "endpoints", "recommend_start.R"))
source(file.path(api_dir, "R", "endpoints", "validate_trip_start.R"))
source(file.path(api_dir, "R", "endpoints", "sensitivity.R"))
source(file.path(api_dir, "R", "endpoints", "experiments.R"))
source(file.path(api_dir, "R", "endpoints", "share_data.R"))
source(file.path(api_dir, "R", "endpoints", "waitlist.R"))
source(file.path(api_dir, "R", "endpoints", "metrics.R"))
source(file.path(api_dir, "R", "endpoints", "share_email.R"))
source(file.path(api_dir, "R", "endpoints", "not_found.R"))
source(file.path(api_dir, "R", "ml", "steps", "step_join_geospatial_features.R"))

# ensure_schema() resolves api/migrations/ from here, exactly as plumber.R does.
model_state$repo_root <- normalizePath(file.path(api_dir, ".."))

# Fake plumber2 objects: handlers only touch `response$status`,
# `response$body`, `response$set_header()` and `request$get_header()`, so
# environments cover them without a server. `set_header` mirrors
# reqres::Response (there is no setHeader on the real object).
fake_response <- function() {
  env <- new.env(parent = emptyenv())
  env$headers <- list()
  env$set_header <- function(name, value) {
    env$headers[[tolower(name)]] <- value
    invisible(NULL)
  }
  env
}

fake_request <- function(headers = list()) {
  list(get_header = function(name) headers[[tolower(name)]])
}

json_raw <- function(x) {
  # Every payload is a JSON object: an empty R list would serialise as the
  # array "[]", which the API rightly rejects as a top level.
  if (is.list(x) && length(x) == 0L) return(charToRaw("{}"))
  charToRaw(if (is.character(x)) x else jsonlite::toJSON(x, auto_unbox = TRUE))
}

# model_state is a process-wide environment: tests snapshot it and restore it
# so each test can plant fake flags without leaking into the next one.
snapshot_model_state <- function() {
  list(
    policy_name = model_state$policy_name,
    tree = model_state$tree,
    valid_hours = model_state$valid_hours
  )
}

restore_model_state <- function(old) {
  model_state$policy_name <- old$policy_name
  model_state$tree <- old$tree
  model_state$valid_hours <- old$valid_hours
}

set_model_state <- function(policy_name = NULL, tree = NULL, valid_hours = NULL) {
  model_state$policy_name <- policy_name
  model_state$tree <- tree
  model_state$valid_hours <- valid_hours
}
