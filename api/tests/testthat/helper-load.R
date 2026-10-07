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
# Where the repository's api/ is. Normally ".." from tests/testthat, but covr
# installs the package into a temporary library and runs the INSTALLED copy of
# these tests from there -- ".." would then be that temp tree, and everything
# that resolves against the repository (contract/openapi.yaml, api/migrations,
# .env) would silently point at nothing. dev/coverage.R exports TAXI_API_DIR
# so the tests know where they really came from.
api_dir <- Sys.getenv("TAXI_API_DIR", "")
api_dir <- if (nzchar(api_dir)) normalizePath(api_dir) else
  normalizePath(file.path("..", ".."))
# The package, not a pile of source() calls (ADR-0007). The two branches are
# not cosmetic: under covr (R_COVR is set) an instrumented copy of taxiapi has
# been installed into a temporary library and has to be the one that runs --
# loading the source instead would instrument nothing and report 0 %. Outside
# coverage, load_all is what a developer expects: edit, re-run, no reinstall.
if (nzchar(Sys.getenv("R_COVR"))) {
  library(taxiapi)
} else {
  pkgload::load_all(api_dir, export_all = TRUE, helpers = FALSE,
                    attach_testthat = FALSE, quiet = TRUE)
}
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
