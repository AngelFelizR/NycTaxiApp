# Load the code under test (share/ is not an installed package, so R/ is
# sourced by hand, exactly like app/). testthat runs with cwd = tests/testthat.
suppressPackageStartupMessages({
  library(plumber2)
  library(reqres)
  library(ggplot2)
  library(patchwork)
  library(ragg)
  library(httr2)
  library(jsonlite)
  library(redux)
})
share_dir <- normalizePath(file.path("..", ".."))

# shared/*.yaml first: render_png.R takes the curve spec from there.
source(file.path(share_dir, "..", "shared", "load.R"))

for (rel in c("R/utils.R", "R/api_client.R", "R/bots.R", "R/cache.R",
              "R/render_png.R", "R/render_html.R", "R/routes.R")) {
  source(file.path(share_dir, rel))
}

# The tests run inside the dev container, where .env lives one level up.
load_dotenv(file.path(share_dir, "..", ".env"))

# A ShareDataResponse exactly as GET /share-data/{token} answers it (contract
# 5.7): aggregated, no PII, no experiment_id. Overrides replace at the top
# level only -- modifyList() would recurse into the history data.frame and
# choke on a zero-row replacement.
share_fixture <- function(...) {
  base <- list(
    day_label = "Day #aZ3kQ9",
    outcome = "beat_model",
    seed_is_custom = FALSE,
    final_user_wage = 27.4,
    final_policy_wage = 24.9,
    final_baseline_wage = 21.2,
    user_percentile = 73,
    pct_following_policy = 88,
    trips_accepted = 7L,
    trips_rejected = 3L,
    label = "I beat the Model!",
    share_text = "I beat the model today. \U0001F695\U0001F4CA",
    history = data.frame(
      step = 0:5,
      user = c(0, 10.5, 20.75, 31.5, 42, 50.25),
      policy = c(0, 12, 24, 36, 48, 60),
      baseline = c(0, 8, 16, 24, 32, 40)
    )
  )
  ov <- list(...)
  for (nm in names(ov)) base[[nm]] <- ov[[nm]]
  base
}
