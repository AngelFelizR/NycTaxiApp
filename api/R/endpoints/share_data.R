# GET /share-data/{token} (section 5.7): the only feed of the public share
# service. Aggregated, PII-free -- never experiment_id, never an email -- and
# only for experiments the player actually finished (404 otherwise, so an
# unfinished day cannot be guessed at from its token).

share_data_handler <- function(request, response, token) {
  if (!is_string(token) || !grepl("^[A-Za-z0-9_-]{12}$", token)) {
    return(api_error(response, 404L, "not_found", "Not found."))
  }
  if (is.null(db_pool())) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  rows <- db_get_experiment_by_token(token)
  if (is.null(rows)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  exp <- first_row(rows)
  if (is.null(exp) || !identical(as.character(exp$status), "finished")) {
    return(api_error(response, 404L, "not_found", "Not found."))
  }

  user <- db_get_decisions(exp$id, "user")
  policy <- db_get_decisions(exp$id, "policy")
  baseline <- db_get_decisions(exp$id, "baseline")
  if (is.null(user) || is.null(policy) || is.null(baseline)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  # First fetch of this token = one share card generated (for /metrics).
  mark_share_generated(token)

  outcome <- as.character(exp$outcome)
  seed_is_custom <- isTRUE(exp$seed_is_custom)
  response$body <- list(
    day_label = paste0("Day #", substr(as.character(exp$share_token), 1, 6)),
    outcome = outcome,
    seed_is_custom = seed_is_custom,
    final_user_wage = as.numeric(exp$final_user_wage),
    final_policy_wage = as.numeric(exp$final_policy_wage),
    final_baseline_wage = as.numeric(exp$final_baseline_wage),
    user_percentile = as.numeric(exp$user_percentile),
    pct_following_policy = as.numeric(exp$pct_following_policy),
    trips_accepted = as.integer(exp$trips_accepted),
    trips_rejected = as.integer(exp$trips_rejected),
    label = outcome_label(outcome, seed_is_custom),
    share_text = outcome_share_text(outcome, seed_is_custom),
    history = history_points(user, policy, baseline)
  )
  plumber2::Break
}
