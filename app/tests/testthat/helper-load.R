# Load the code under test (the app is not a package, so we source R/ by hand).
# testthat runs with the working directory set to tests/testthat.
#
# Mirrors app.R exactly: everything under R/ (Shiny autoloads the top level of
# that directory but never descends into R/modules/), then the modules. All
# files only define functions, so the alphabetical order is safe.
suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(leaflet)
  library(ggplot2)
  library(httr2)
})
app_dir <- normalizePath(file.path("..", ".."))

# shared/*.yaml first: strings.R builds its label_curve_* aliases from
# curve_labels(). Also makes R/shared_config.R's candidate loop a no-op.
source(file.path(app_dir, "..", "shared", "load.R"))

for (rel in c(
  list.files(file.path(app_dir, "R"), pattern = "\\.[rR]$"),
  file.path("modules", list.files(file.path(app_dir, "R", "modules"),
                                  pattern = "\\.[rR]$"))
)) {
  source(file.path(app_dir, "R", rel))
}

# The tests run inside the dev container, where .env lives one level up.
load_env_file(file.path(app_dir, "..", ".env"))

# The smallest thing that satisfies client_ip(): it only reads
# session$request.<header>. Shared by every test that builds an estado.
fake_session <- function(headers = list()) {
  structure(list(request = headers), class = "MockShinySession2")
}
