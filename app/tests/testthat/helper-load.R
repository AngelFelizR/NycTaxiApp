# Load the code under test (the app is not a package, so we source R/ by hand).
# testthat runs with the working directory set to tests/testthat.
suppressPackageStartupMessages({
  library(shiny)
  library(ggplot2)
  library(httr2)
})
app_dir <- normalizePath(file.path("..", ".."))
source(file.path(app_dir, "R", "api_client.R"))
source(file.path(app_dir, "R", "utils.R"))
