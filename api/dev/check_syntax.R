files <- c("api/plumber.R", list.files("api/R", pattern = "[.]R$", recursive = TRUE, full.names = TRUE))
for (f in files) {
  tryCatch({ parse(f); cat("OK", f, "\n") },
           error = function(e) { cat("FAIL", f, "-", conditionMessage(e), "\n"); quit(status = 1) })
}
