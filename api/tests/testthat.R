# Run from api/:  Rscript tests/testthat.R
#
# The directory comes from this file, not from the working directory, because
# covr runs the very same script from its own temporary tree -- where
# "tests/testthat" does not exist relative to wherever it happens to be
# standing. Landing in api/tests is also what helper-load.R assumes: testthat
# then sources the helpers with cwd at tests/testthat, so ".." is api/.
library(testthat)
this_file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
if (length(this_file) && nzchar(this_file[[1L]])) {
  setwd(dirname(normalizePath(this_file[[1L]])))
}
test_dir("testthat")
