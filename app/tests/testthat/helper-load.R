# Load the code under test (the app is not a package, so we source R/ by hand).
# testthat runs with the working directory set to tests/testthat.
#
# Shiny itself only autoloads the top level of R/ and never descends into
# R/modules/, so this helper mirrors app.R: everything, in dependency order.
suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(leaflet)
  library(ggplot2)
  library(httr2)
})
app_dir <- normalizePath(file.path("..", ".."))

for (rel in c(
  "R/api_client.R",
  "R/constants.R",
  "R/strings.R",
  "R/state.R",
  "R/theme.R",
  "R/utils.R",
  "R/mod_setup.R",
  "R/mod_trips.R",
  file.path("R", "modules", c("mod_header.R", "mod_results.R",
                              "mod_confirm_modal.R"))
)) {
  source(file.path(app_dir, rel))
}

# The tests run inside the dev container, where .env lives one level up.
load_env_file(file.path(app_dir, "..", ".env"))
