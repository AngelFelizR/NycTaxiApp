# Load the code under test. testthat runs with the working directory set to
# tests/testthat; app.R is mirrored exactly (ADR-0007): the package, never a
# pile of source() calls -- R/ is flat now, and R/_disable_autoload.R stops
# Shiny from loading a second copy into the test environment.
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

# Under covr (R_COVR is set) an instrumented copy of taxiapp has been
# installed into a temporary library and has to be the one that runs;
# load_all() would overwrite it with uninstrumented source and report 0 %.
if (nzchar(Sys.getenv("R_COVR"))) {
  library(taxiapp)
} else {
  pkgload::load_all(app_dir, export_all = TRUE, helpers = FALSE,
                    attach_testthat = FALSE, quiet = TRUE)
}

# The tests run inside the dev container, where .env lives one level up.
load_env_file(file.path(app_dir, "..", ".env"))

# The smallest thing that satisfies client_ip(): it only reads
# session$request.<header>. Shared by every test that builds an estado.
fake_session <- function(headers = list()) {
  structure(list(request = headers), class = "MockShinySession2")
}
