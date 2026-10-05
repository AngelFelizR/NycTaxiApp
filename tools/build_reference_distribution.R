#!/usr/bin/env Rscript
# Generates ReferenceDistribution.qs2 (master doc section 4.6): the offline
# distribution of policy (and baseline) wages over >= 1,000 seeds and valid
# start conditions per company, produced with the very same simulator the API
# runs in /experiments so percentiles are self-consistent.
#
# Run it inside the API shell (data at /data, models at /models in the dev
# container):
#
#   nix-shell api/default.dev.nix --run \
#     "Rscript tools/build_reference_distribution.R --seeds 1000 --jobs 4"
#
# Options:
#   --seeds N   seeds per company (>= 1000; the doc's minimum)
#   --jobs N    forked workers (default 4)
#   --out PATH  output file (default models_dir()/ReferenceDistribution.qs2)

args <- commandArgs(trailingOnly = TRUE)
opt <- function(flag, default) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[[i + 1L]]
}
n_seeds <- as.integer(opt("--seeds", "1000"))
jobs <- max(1L, as.integer(opt("--jobs", "4")))
out_path <- opt(
  "--out",
  file.path(Sys.getenv("TAXI_MODELS_DIR", "/models"), "ReferenceDistribution.qs2")
)
if (is.na(n_seeds) || n_seeds < 1L) stop("--seeds must be a positive integer")

all_args <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- if (length(all_args) > 0) {
  sub("^--file=", "", all_args[[1]])
} else {
  file.path("tools", "build_reference_distribution.R")
}
root <- normalizePath(file.path(dirname(script_path), ".."))

suppressPackageStartupMessages({
  library(qs2)
  library(mori)
  library(jsonlite)
  library(lubridate)
  library(data.table)
  library(workflows)
  library(parsnip)
  library(recipes)
  library(themis)
  library(embed)
  library(timeDate)
  library(tailor)
  library(ggplot2)
  library(nanoparquet)
})

for (rel in c(
  "R/utils.R",
  "R/data/trips.R",
  "R/ml/load_model.R",
  "R/ml/perf.R",
  "R/ml/predict.R",
  "R/ml/simulate.R",
  "R/ml/outcome.R"
)) source(file.path(root, "api", rel))
# The fitted recipes bake through this custom step, so its S3 methods must be
# registered exactly as plumber.R does.
source(file.path(root, "api", "R", "ml", "steps", "step_join_geospatial_features.R"))

# Same warm caches as the API process: without them every predict pays for the
# holiday calendars and the tibble machinery (~150 ms of the ~197 ms).
invisible(install_time_speedups())
invisible(install_bake_speedups())

if (!load_models()) stop("models failed to load under ", models_dir())
if (!load_trip_data()) stop("trip data failed to load under ", data_dir())

companies <- c("Lyft", "Uber")
zones <- which(data_state$zone_ok)

# Start datetimes a player can actually pick: an hour inside the simulated
# week for which the whole 8h30 shift still has data, and whose weekday/hour
# is in the model's ValidHoursToStartWorking lookup.
start_grid <- function() {
  range <- trip_data_range()
  shift <- (SIM_SHIFT_HOURS * 3600 + SIM_BREAK_MINUTES * 60)
  grid <- seq(
    lubridate::floor_date(range[[1]], unit = "hour"),
    range[[2]] - shift,
    by = "hour"
  )
  cycles <- sort(unique(model_state$valid_hours$week_cycle))
  cycle <- (as.integer(lubridate::wday(grid)) - 1L) * 24L + lubridate::hour(grid)
  grid[cycle %in% cycles]
}
grid <- start_grid()
if (length(grid) == 0L || length(zones) == 0L) stop("empty start conditions")

# Start conditions come from a second stream derived from the seed, so they
# vary across seeds but stay reproducible; simulate_day() then re-seeds with
# the seed itself.
start_for <- function(seed) {
  set.seed(normalize_seed(seed) + 7919L)
  list(
    datetime = grid[[sample.int(length(grid), 1L)]],
    location = zones[[sample.int(length(zones), 1L)]]
  )
}

wages_for <- function(company, seed) {
  start <- start_for(seed)
  code <- company_to_hvfhs(company)
  policy <- simulate_day(seed, code, start$datetime, start$location, "policy")
  baseline <- simulate_day(seed, code, start$datetime, start$location, "baseline")
  if (!is.null(policy$error) || !is.null(baseline$error)) {
    return(c(policy = NA_real_, baseline = NA_real_))
  }
  c(policy = wage_per_hour(policy$decisions), baseline = wage_per_hour(baseline$decisions))
}

t0 <- proc.time()[["elapsed"]]
result <- list()
for (company in companies) {
  t_c <- proc.time()[["elapsed"]]
  got <- parallel::mclapply(
    seq_len(n_seeds),
    function(i) wages_for(company, i),
    mc.cores = jobs,
    mc.preschedule = FALSE
  )
  mat <- do.call(rbind, got)
  policy <- mat[, "policy"]
  baseline <- mat[, "baseline"]
  dropped <- sum(is.na(policy) | is.na(baseline))
  result[[company]] <- list(policy = policy, baseline = baseline)
  cat(sprintf(
    "%s: %d seeds (%d dropped) in %.1fs\n",
    company, n_seeds, dropped, proc.time()[["elapsed"]] - t_c
  ), file = stderr())
}

reference <- list(
  by_company = lapply(result, `[[`, "policy"),
  baseline_by_company = lapply(result, `[[`, "baseline"),
  meta = list(
    n_seeds = n_seeds,
    companies = companies,
    generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    model_version = Sys.getenv("MODEL_VERSION", "0.0.1-data"),
    start_conditions = "valid-hour cycles from ValidHoursToStartWorking.qs2, random zone with outgoing trips",
    shift_hours = SIM_SHIFT_HOURS + SIM_BREAK_MINUTES / 60
  )
)

dir.create(dirname(out_path), showWarnings = FALSE, recursive = TRUE)
qs2::qs_save(reference, out_path)
cat(sprintf(
  "wrote %s (%.1f KB, total %.1fs)\n",
  out_path, file.size(out_path) / 1024,
  proc.time()[["elapsed"]] - t0
), file = stderr())
