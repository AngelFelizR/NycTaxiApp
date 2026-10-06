# Bridge between the app and shared/ (docs/decisions/0003).
#
# Shiny sources R/*.R BEFORE the body of app.R runs (verified: an app whose
# app.R prints after its R/ files prints the R/ files first), and strings.R
# builds its label_curve_* aliases from curve_labels() -- so the loader has to
# live inside R/ and sort before strings.R (R/ is sourced alphabetically:
# constants -> shared_config -> state -> strings).
#
# The candidates mirror shared/load.R's own lookup: the working directory is
# app/ in production and app/tests/testthat under testthat.
if (!exists("curve_labels", mode = "function", inherits = TRUE)) {
  cands <- c(
    if (nzchar(Sys.getenv("SHARED_DIR"))) file.path(Sys.getenv("SHARED_DIR"), "load.R"),
    file.path("..", "shared", "load.R"),
    file.path("shared", "load.R"),
    file.path("..", "..", "shared", "load.R")
  )
  hit <- cands[file.exists(cands)]
  if (length(hit) == 0) {
    stop("shared/load.R not found (tried: ", paste(cands, collapse = ", "),
         "). Set SHARED_DIR to the directory that holds shared/*.yaml.",
         call. = FALSE)
  }
  # local = TRUE: the functions must land in the very environment R/ is being
  # sourced into (Shiny's shared environment, or app.R's own), not globalenv.
  source(hit[1], local = TRUE)
}
