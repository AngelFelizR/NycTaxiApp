# Model loading (section 5.9): everything is loaded in the main process
# before plumber2 starts. The policy (345 MB qs2, ~2 GB expanded) is
# sanitised, shared through mori and the in-memory copy is dropped; each
# process then maps the shared segment and rebuilds plain list wrappers with
# deshare_lists() so predict() can write to its inputs while the bulk data
# stays in zero-copy shared memory.

model_state <- new.env(parent = emptyenv())

sanitize_quosures <- function(x) {
  if (inherits(x, "quosure")) {
    environment(x) <- new.env(parent = globalenv())
    return(x)
  }
  if (is.data.frame(x)) return(x)
  if (is.list(x)) {
    for (i in seq_along(x)) x[i] <- list(sanitize_quosures(x[[i]]))
    return(x)
  }
  x
}

# Rebuild every list node as a plain R list (recursing into elements) so that
# predict() can assign into the workflow. Atomic leaves keep pointing into the
# shared segment: mori_list ALTREP objects reject Set_elt, plain wrappers do
# not. NULL elements need `[i] <- list(...)`, plain `[[i]] <-` would drop them.
deshare_lists <- function(x) {
  if (is.list(x)) {
    n <- length(x)
    el <- vector("list", n)
    for (i in seq_len(n)) el[i] <- list(deshare_lists(x[[i]]))
    attributes(el) <- attributes(x)
    el
  } else {
    x
  }
}

models_dir <- function() Sys.getenv("TAXI_MODELS_DIR", "/models")

load_models <- function() {
  policy_path <- file.path(models_dir(), "AcceptRejectPolicyFitted.qs2")
  policy_raw <- qs2::qs_read(policy_path)
  policy_wf <- sanitize_quosures(policy_raw)
  rm(policy_raw)
  invisible(gc())
  model_state$policy_shared <- mori::share(policy_wf)
  model_state$policy_name <- mori::shared_name(model_state$policy_shared)
  rm(policy_wf)
  invisible(gc())
  model_state$policy <- NULL

  model_state$tree <- qs2::qs_read(file.path(models_dir(), "DecisionTreeWfFitted.qs2"))
  model_state$valid_hours <- qs2::qs_read(file.path(models_dir(), "ValidHoursToStartWorking.qs2"))
  invisible(TRUE)
}

# Process-local cache: the first call in each process maps the shared segment
# (cheap) and materialises the list wrappers (milliseconds).
policy_workflow <- function() {
  if (is.null(model_state$policy)) {
    if (is.null(model_state$policy_name)) return(NULL)
    mapped <- mori::map_shared(model_state$policy_name)
    model_state$policy <- deshare_lists(mapped)
  }
  model_state$policy
}

# TRUE when the fitted policy's postprocessor only derives classes from
# probabilities (binary threshold adjustments, as fitted today): tailor then
# never changes the probability columns, so policy_probability() can skip the
# augment + tailor round trip (~15-20 ms per predict) and go straight through
# forge() + predict(parsnip fit). Cached per process.
policy_prob_is_raw <- function() {
  if (!is.null(model_state$policy_prob_is_raw)) {
    return(model_state$policy_prob_is_raw)
  }
  raw <- TRUE
  wf <- policy_workflow()
  if (!is.null(wf)) {
    post <- tryCatch(
      workflows::extract_postprocessor(wf, estimated = TRUE),
      error = function(e) NULL
    )
    if (!is.null(post) && length(post$adjustments) > 0) {
      raw <- all(vapply(post$adjustments, function(adj) {
        inherits(adj, "probability_threshold") &&
          !("probability" %in% adj$outputs)
      }, logical(1)))
    }
  }
  model_state$policy_prob_is_raw <- raw
  raw
}

models_status <- function() {
  list(
    policy = !is.null(model_state$policy_name),
    start_validator = !is.null(model_state$tree),
    valid_hours = !is.null(model_state$valid_hours),
    reference_distribution = file.exists(file.path(models_dir(), "ReferenceDistribution.qs2"))
  )
}
