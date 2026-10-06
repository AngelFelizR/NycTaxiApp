# Everything the share service reads from the environment (sections 5.10 and
# 7.2). No database credentials exist here by design: the API is the only
# component that may touch Postgres.

`%||%` <- function(x, y) if (is.null(x)) y else x

# KEY=VALUE pairs from a file, never overriding what the environment already
# carries (Docker and ShinyProxy inject the real values in production).
load_dotenv <- function(path) {
  if (!file.exists(path)) return(invisible(FALSE))
  lines <- trimws(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "#")]
  for (line in lines) {
    if (!grepl("=", line, fixed = TRUE)) next
    key <- trimws(sub("=.*$", "", line))
    value <- trimws(sub("^[^=]*=", "", line))
    if (nzchar(key) && !nzchar(Sys.getenv(key))) {
      do.call(Sys.setenv, stats::setNames(list(value), key))
    }
  }
  invisible(TRUE)
}

# The public origin the share URLs are built from (section 7.2: og:image and
# og:url are absolute, and the CTA points back at the app).
share_base_url <- function() {
  url <- sub("/+$", "", Sys.getenv("SHARE_BASE_URL",
                                   "https://nyctaxiapp.angelfeliz.com"))
  if (!nzchar(url)) "https://nyctaxiapp.angelfeliz.com" else url
}

# A11y/UX rule for the whole service: one place decides whether a value can be
# shown, so an unexpected NULL from the API becomes "--" instead of an error.
show_num <- function(x, digits = 2, prefix = "", suffix = "") {
  if (is.null(x) || length(x) == 0 || is.na(x[1])) return("--")
  paste0(prefix, formatC(as.numeric(x[1]), format = "f", digits = digits), suffix)
}

# Escape the handful of API strings that end up inside HTML. The copy comes
# from the API, so it is treated as untrusted even though it is ours.
html_escape <- function(x) {
  x <- as.character(x %||% "")[1]
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# 4.6 renders the percentile as "the 21st percentile"; 11/12/13 are the
# irregulars and every -11/-12/-13 inherits them.
ordinal <- function(n) {
  n <- as.integer(round(as.numeric(n)[1]))
  if (is.na(n)) return("")
  sfx <- if (n %% 100 %in% c(11, 12, 13)) "th" else
    switch(as.character(n %% 10), "1" = "st", "2" = "nd", "3" = "rd", "th")
  paste0(n, sfx)
}
