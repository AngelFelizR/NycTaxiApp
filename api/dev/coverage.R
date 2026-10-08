#!/usr/bin/env Rscript
# Section 10's coverage numbers, for the API package.
#
#   nix-shell default.dev.nix --run "Rscript dev/coverage.R"     (cwd = api/)
#
# It lives in dev/ and not in tests/ for a reason: covr runs every .R file of
# tests/ as part of the measurement, so a coverage script sitting there would
# measure itself, recursively, forever.
#
# covr installs the package into a temporary library with the instrumentation
# in it and runs the copy of tests/ it installed there. That copy resolves
# ".." against the temp tree, so TAXI_API_DIR is exported below and
# helper-load.R / contract_path() follow it back to the repository. And
# helper-load.R sees R_COVR and calls library(taxiapi) instead of load_all();
# without that branch the number would be zero, because load_all() would
# overwrite the instrumented code with plain source.
#
# The report is the deliverable. Section 10 sets a bar (60% globally, 100% on
# seven files) but nothing here knows whether today's number clears it, so the
# run only fails when COVERAGE_FAIL_UNDER is set -- CI can turn enforcement on
# once a first number exists, instead of going red on a guess.

suppressPackageStartupMessages(library(covr))

# covr installs the package into a temp library and runs the tests it
# installed there; helper-load.R and contract_path() would otherwise resolve
# ".." against that tree and lose the repository.
Sys.setenv(TAXI_API_DIR = normalizePath("."))

fail_under <- suppressWarnings(as.numeric(Sys.getenv("COVERAGE_FAIL_UNDER", "")))
if (length(fail_under) != 1L || is.na(fail_under)) fail_under <- NA_real_

# Per-file bar, a separate switch: section 10 asks for 100% on the seven
# critical files, and CI holds both. Two switches so the global figure can
# stay enforced even while a per-file number is being agreed.
fail_critical <- identical(Sys.getenv("COVERAGE_FAIL_CRITICAL", ""), "1")

res <- package_coverage(path = ".", quiet = TRUE)

# percent_coverage() already returns a percentage; asking for it per file
# means subsetting the coverage object, because it knows how to weight
# expressions and a naive mean of `value > 0` disagrees with it. A coverage
# object is a flat list of one entry per expression with a srcref -- the file
# name lives on the srcref's srcfile, not on the entry.
srcfile_of <- function(e) {
  sf <- attr(e$srcref, "srcfile")
  fn <- if (is.null(sf)) NULL else tryCatch(sf$filename, error = function(z) NULL)
  if (is.null(fn) || !nzchar(fn)) NA_character_ else fn
}
owner <- vapply(res, srcfile_of, character(1))
global <- percent_coverage(res)
files <- sort(unique(owner[!is.na(owner)]))
by_file <- sort(vapply(files, function(f) {
  percent_coverage(res[owner %in% f])
}, numeric(1)), decreasing = TRUE)

# The critical files of section 10, under the names they have since ADR-0007
# flattened R/. A rename that loses one of them has to change this list, which
# is the point: the list IS the requirement.
critical <- c(
  "ml_sensitivity.R", "middleware_rate_limit.R", "db_migrations.R",
  "ml_simulate.R", "middleware_internal_auth.R", "middleware_client_ip.R",
  "ml_outcome.R"
)
crit <- by_file[match(critical, basename(names(by_file)))]
missing_crit <- critical[is.na(crit)]

lines <- c(
  sprintf("**global: %.1f%%** (section 10 asks for 60%%)", global),
  "",
  "section 10's critical files (100% each):",
  sprintf("- %s: %.1f%%", critical, crit)
)
if (length(missing_crit)) {
  lines <- c(lines, "", paste("- NOT IN THE REPORT:", missing_crit))
}
lines <- c(
  lines, "",
  paste0(
    if (is.na(fail_under)) "enforcement: global off" else
      sprintf("enforcement: global >= %.0f%%", fail_under),
    if (fail_critical) "; critical files 100% each"
      else "; critical files reported only"
  ),
  "", "<details><summary>per file</summary>", "",
  sprintf("- %s: %.1f%%", basename(names(by_file)), by_file),
  "", "</details>"
)
cat(paste(lines, collapse = "\n"), "\n")

if (nzchar(Sys.getenv("GITHUB_STEP_SUMMARY"))) {
  cat(paste(c("**API coverage** (section 10)", lines[-1], ""),
            collapse = "\n"),
      file = Sys.getenv("GITHUB_STEP_SUMMARY"), append = TRUE)
}

# The seven critical files must all be present before any percentage means
# anything, and that much is checkable without knowing the number.
if (length(missing_crit)) {
  stop("critical files missing from the coverage report: ",
       paste(missing_crit, collapse = ", "))
}
if (!is.na(fail_under) && global < fail_under) {
  stop(sprintf("coverage %.1f%% is below the required %.0f%%",
               global, fail_under))
}
if (fail_critical) {
  short <- !is.na(crit) & crit < 100
  if (any(short)) {
    stop(sprintf(
      "section 10 wants 100%% on every critical file; short: %s",
      paste(sprintf("%s=%.1f%%", critical[short], 100 * crit[short]),
            collapse = ", ")
    ))
  }
}
