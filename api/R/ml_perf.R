# Startup speedups for the phase-1 latency budget (doc line: curl < 100ms
# with models loaded). Two recipe steps dominate predict() because they call
# timeDate holiday calendars on every bake:
#
#   * step_holiday      -> recipes:::is_holiday -> timeDate::holiday(): ~5.5ms
#                          per calendar x 18 calendars ~= 94ms per predict.
#   * step_mutate       -> 18 "Days to US<Calendar>(year)" expressions,
#                          ~1.1ms each ~= 20ms of the ~45ms step.
#
# Both are pure functions of their arguments (holiday dates for a year never
# change), so memoizing them is exact: same outputs, cache hits after the
# first call per (year, calendar).

# Wrap `name` in `env` with a memoizing closure. Ignores anything that is
# already wrapped or is not a function.
memoize_binding <- function(name, env) {
  if (!exists(name, envir = env, inherits = FALSE)) {
    return(FALSE)
  }
  original <- get(name, envir = env, inherits = FALSE)
  if (!is.function(original) || isTRUE(attr(original, "nyc_memo"))) {
    return(FALSE)
  }
  cache <- new.env(parent = emptyenv())
  memo <- function(...) {
    args <- list(...)
    key <- digest::digest(args, algo = "xxhash64")
    if (exists(key, envir = cache, inherits = FALSE)) {
      return(get(key, envir = cache, inherits = FALSE))
    }
    result <- original(...)
    assign(key, result, envir = cache)
    result
  }
  attr(memo, "nyc_memo") <- TRUE
  was_locked <- bindingIsLocked(name, env)
  if (was_locked) unlockBinding(name, env)
  assign(name, memo, envir = env)
  if (was_locked) lockBinding(name, env)
  TRUE
}

install_time_speedups <- function() {
  targets <- c(
    "holiday",
    grep("^US[A-Z]", ls(asNamespace("timeDate"), all.names = TRUE), value = TRUE)
  )
  envs <- list(asNamespace("timeDate"))
  # recipes:::is_holiday resolves `holiday` through its imports environment.
  envs <- c(envs, list(parent.env(asNamespace("recipes"))))
  if ("package:timeDate" %in% search()) {
    envs <- c(envs, list(as.environment("package:timeDate")))
  }
  patched <- 0L
  for (env in envs) {
    for (nm in targets) {
      patched <- patched + as.integer(memoize_binding(nm, env))
    }
  }
  # get_holiday_features (the whole of step_holiday) converts the cached
  # timeDate results on every call; memoizing it removes ~35ms per predict.
  patched <- patched + as.integer(
    memoize_binding("get_holiday_features", asNamespace("recipes"))
  )
  invisible(patched)
}

# Faster equivalents of two recipes bake methods. Both were measured with
# Rprof on the fitted policy recipe: step_impute_median spent ~31 ms and
# step_rename ~7.6 ms per single-row bake, almost entirely in tibble/dplyr
# dispatch machinery. Outputs are validated against the originals by
# api/tests (golden bake + predict comparisons).
bake_impute_median_fast <- function(object, new_data, ...) {
  col_names <- names(object$medians)
  recipes:::check_new_data(col_names, object, new_data)
  for (col_name in col_names) {
    median <- object$medians[[col_name]]
    col <- new_data[[col_name]]
    if (sparsevctrs::is_sparse_vector(col)) {
      new_data[[col_name]] <- sparsevctrs::sparse_replace_na(col, median)
      next
    }
    if (anyNA(col)) {
      col <- vctrs::vec_cast(col, median)
      col[is.na(col)] <- median
      new_data[[col_name]] <- col
    }
  }
  new_data
}

bake_rename_fast <- function(object, new_data, ...) {
  inputs <- object$inputs
  old <- vapply(inputs, function(q) {
    e <- rlang::quo_get_expr(q)
    if (rlang::is_symbol(e)) as.character(e) else NA_character_
  }, character(1), USE.NAMES = FALSE)
  nms <- names(new_data)
  pos <- match(old, nms)
  if (anyNA(old) || anyNA(pos) || anyDuplicated(old)) {
    return(dplyr::rename(new_data, !!!object$inputs))
  }
  nms[pos] <- names(inputs)
  names(new_data) <- nms
  new_data
}

install_bake_speedups <- function() {
  # recipes::bake.recipe() dispatches on the namespace binding
  # recipes:::bake.step_* (proven empirically: a registered S3 method fires
  # only for calls made from outside the recipes frame, the locked ns binding
  # wins inside bake.recipe), so the binding itself has to be replaced.
  ns <- asNamespace("recipes")
  for (pair in list(
    c("bake.step_impute_median", bake_impute_median_fast),
    c("bake.step_rename", bake_rename_fast)
  )) {
    unlockBinding(pair[[1]], ns)
    assign(pair[[1]], pair[[2]], envir = ns)
    lockBinding(pair[[1]], ns)
    registerS3method(
      "bake", sub("^bake\\.", "", pair[[1]]), pair[[2]], envir = ns
    )
  }
  invisible(2L)
}
