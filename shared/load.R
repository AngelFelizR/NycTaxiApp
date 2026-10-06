# The only code in shared/: it locates, reads and VALIDATES shared/*.yaml so
# app/ and share/ render with one visual spec (docs/decisions/0003).
#
# YAML has no schema, so the validators below are the whole safety net -- a
# typo would otherwise turn into an NA in the middle of a chart. They are
# exported (not inlined) precisely so both test suites can feed them garbage.
#
# This file must be sourced BEFORE the code that reads it: app/R/strings.R
# builds its label_curve_* aliases from curve_labels().

# trimws+coerce without leaning on `%||%`, which the services define later.
shared_value <- function(x, default = "") {
  if (is.null(x) || length(x) == 0) return(default)
  v <- trimws(as.character(x[[1]]))
  if (is.na(v)) default else v
}

is_hex6 <- function(x) grepl("^#[0-9a-fA-F]{6}$", x)

# Locate shared/ by candidate rather than by an absolute path: the working
# directory is the repo root, a service directory, or a testthat directory
# depending on who loads this, and production may place it anywhere (the same
# trick app_data_dir() uses for the data volume).
shared_dir <- function() {
  cands <- c(
    Sys.getenv("SHARED_DIR", ""),
    "shared",
    file.path("..", "shared"),
    file.path("..", "..", "shared"),
    file.path("..", "..", "..", "shared"),
    "/srv/nyctaxi/shared"
  )
  cands <- cands[nzchar(cands)]
  hit <- cands[file.exists(file.path(cands, "curves.yaml"))]
  if (length(hit) == 0) {
    stop("shared/curves.yaml not found. Tried: ",
         paste(cands, collapse = ", "),
         ". Set SHARED_DIR to the directory that holds it.", call. = FALSE)
  }
  normalizePath(hit[1])
}

validate_curves <- function(curves) {
  bad <- function(msg) stop("shared/curves.yaml: ", msg, call. = FALSE)
  if (!is.list(curves) || !is.list(curves$series)) {
    bad("expected a `series:` list.")
  }
  s <- curves$series
  # Before the length check: `list("You")` is a wrong shape, not a wrong count.
  if (!all(vapply(s, is.list, logical(1)))) {
    bad("every entry of `series` must be a mapping with name/label/colour.")
  }
  if (length(s) != 3L) {
    bad(sprintf("expected exactly 3 series, got %d.", length(s)))
  }
  expect <- c("user", "policy", "baseline")
  nm <- vapply(s, function(x) shared_value(x$name), "")
  if (!identical(nm, expect)) {
    bad(sprintf("`name` must be %s in that order, got [%s].",
                paste(expect, collapse = ", "), paste(nm, collapse = ", ")))
  }
  lab <- vapply(s, function(x) shared_value(x$label), "")
  if (any(!nzchar(lab))) bad("every `label` must be a non-empty string.")
  if (anyDuplicated(lab) > 0) {
    bad(sprintf("`label` values must be unique, got [%s].",
                paste(lab, collapse = ", ")))
  }
  col <- vapply(s, function(x) shared_value(x$colour), "")
  if (any(!is_hex6(col))) {
    bad(paste0(
      "`colour` must be a quoted 6-digit hex such as \"#6d5dfc\"; got [",
      paste(col[!is_hex6(col)], collapse = ", "),
      "]. A bare # starts a YAML comment and parses as null."))
  }
  if (anyDuplicated(col) > 0) {
    bad(sprintf("`colour` values must be unique, got [%s].",
                paste(col, collapse = ", ")))
  }
  data.frame(name = nm, label = lab, colour = col, stringsAsFactors = FALSE)
}

validate_brand <- function(brand) {
  bad <- function(msg) stop("shared/brand.yaml: ", msg, call. = FALSE)
  if (!is.list(brand)) bad("expected a mapping with `primary` and `primary_dark`.")
  keys <- c("primary", "primary_dark")
  missing <- setdiff(keys, names(brand))
  if (length(missing) > 0L) {
    bad(sprintf("missing %s.", paste(sprintf("`%s`", missing), collapse = " and ")))
  }
  hex <- vapply(keys, function(k) shared_value(brand[[k]]), "")
  names(hex) <- keys
  if (any(!is_hex6(hex))) {
    bad(paste0(
      "`", keys[!is_hex6(hex)][1],
      "` must be a quoted 6-digit hex; got [", hex[!is_hex6(hex)][1],
      "]. A bare # starts a YAML comment and parses as null."))
  }
  if (identical(unname(hex[1]), unname(hex[2]))) {
    bad("`primary` and `primary_dark` must be different colours.")
  }
  as.list(hex)
}

shared_state <- new.env(parent = emptyenv())

# Parsed once and cached: two YAML files cost milliseconds, but every curve
# legend and every Leaflet stroke reads through here.
shared_config <- function(force = FALSE) {
  if (!force && !is.null(shared_state$cfg)) return(shared_state$cfg)
  dir <- shared_dir()
  cfg <- list(
    dir = dir,
    series = validate_curves(yaml::read_yaml(file.path(dir, "curves.yaml"))),
    brand = validate_brand(yaml::read_yaml(file.path(dir, "brand.yaml")))
  )
  shared_state$cfg <- cfg
  cfg
}

# Drop the cache so a test (or a watcher) re-reads the files.
shared_reset <- function() {
  shared_state$cfg <- NULL
  invisible(TRUE)
}

# ---- accessors ---------------------------------------------------------------

curve_specs <- function() shared_config()$series

# Named by series name: `user`, `policy`, `baseline`.
curve_labels <- function() {
  s <- curve_specs()
  stats::setNames(s$label, s$name)
}

# Named by legend label, which is what ggplot2's manual scale looks up.
curve_colours <- function() {
  s <- curve_specs()
  stats::setNames(s$colour, s$label)
}

brand_colour <- function(variant = "primary") {
  b <- shared_config()$brand
  v <- as.character(variant)[1]
  if (!v %in% names(b)) {
    stop("brand_colour(): unknown variant '", v, "'. Use one of: ",
         paste(names(b), collapse = ", "), call. = FALSE)
  }
  b[[v]]
}
