# Load the code under test (api/ is not an installed package, so R/ is
# sourced by hand, mirroring app/tests/testthat/helper-load.R). testthat runs
# with the working directory set to tests/testthat.
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
source(file.path(api_dir, "R", "db", "pool.R"))
source(file.path(api_dir, "R", "ml", "load_model.R"))
source(file.path(api_dir, "R", "ml", "perf.R"))
source(file.path(api_dir, "R", "ml", "predict.R"))
source(file.path(api_dir, "R", "ml", "recommend.R"))
source(file.path(api_dir, "R", "middleware", "internal_auth.R"))
source(file.path(api_dir, "R", "endpoints", "health.R"))
source(file.path(api_dir, "R", "endpoints", "predict.R"))
source(file.path(api_dir, "R", "endpoints", "recommend_start.R"))
source(file.path(api_dir, "R", "endpoints", "validate_trip_start.R"))
source(file.path(api_dir, "R", "endpoints", "not_found.R"))
source(file.path(api_dir, "R", "ml", "steps", "step_join_geospatial_features.R"))

# Fake plumber2 objects: handlers only touch `response$status` / `response$body`
# and `request$get_header()`, so environments cover them without a server.
fake_response <- function() new.env(parent = emptyenv())

fake_request <- function(headers = list()) {
  list(get_header = function(name) headers[[tolower(name)]])
}

json_raw <- function(x) {
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
