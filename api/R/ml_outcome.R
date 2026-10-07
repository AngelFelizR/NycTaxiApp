# Results of a finished day (section 3.9, 3.10, 4.6, 6.6): wages, the
# outcome verdict, the share copy and the percentile against the reference
# distribution. Everything here is computed on the server; the UI and the
# share service only render it.

# Wage = (sum driver_pay + sum tips) / shift hours, idle time included and the
# 30-minute break excluded (ADR-025). Same formula for the three trajectories.
day_earnings <- function(decisions) {
  if (is.null(decisions) || nrow(decisions) == 0L) return(0)
  keep <- decisions$accepted %in% TRUE
  if (!any(keep)) return(0)
  sum(decisions$driver_pay[keep]) + sum(decisions$tips[keep])
}

wage_per_hour <- function(decisions, hours = SIM_SHIFT_HOURS) {
  round(day_earnings(decisions) / hours, 2)
}

# Section 3.10 precedence: no_rides > beat_model > tied_model > beat_baseline
# > lost_to_baseline, with the 0.01 tolerance that makes rounding invisible.
compute_outcome <- function(user_wage, policy_wage, baseline_wage, trips_accepted) {
  if (trips_accepted == 0L) return("no_rides")
  if (user_wage > policy_wage + 0.01) return("beat_model")
  if (abs(user_wage - policy_wage) <= 0.01) return("tied_model")
  if (user_wage > baseline_wage) return("beat_baseline")
  "lost_to_baseline"
}

# Percentage of the player's decisions that matched the model recommendation.
# No decisions yet reads as 100 (contract example for a fresh experiment).
pct_following_policy <- function(decisions) {
  if (is.null(decisions) || nrow(decisions) == 0L) return(100)
  rec <- decisions$model_recommended
  ok <- !is.na(rec)
  if (!any(ok)) return(100)
  round(100 * mean(as.logical(decisions$accepted[ok]) == as.logical(rec[ok])), 2)
}

trips_count <- function(decisions, accepted) {
  if (is.null(decisions) || nrow(decisions) == 0L) return(0L)
  sum(decisions$accepted %in% accepted)
}

# ---- reference distribution (section 4.6) ---------------------------------

# ReferenceDistribution.qs2 is produced offline by
# tools/build_reference_distribution.R (1,000+ simulated model days per
# company, same simulator, same rules). Loaded lazily and cached.
reference_distribution <- function() {
  if (!is.null(model_state$reference)) return(model_state$reference)
  path <- file.path(models_dir(), "ReferenceDistribution.qs2")
  if (!file.exists(path)) return(NULL)
  ref <- tryCatch(qs2::qs_read(path), error = function(e) NULL)
  if (is.null(ref)) return(NULL)
  model_state$reference <- ref
  ref
}

# Percentile of the user's wage inside their company's reference distribution
# (0-100, one decimal). NULL when the file is missing or empty: finish then
# answers 503 instead of storing a made-up number.
reference_percentile <- function(company, wage) {
  ref <- reference_distribution()
  if (is.null(ref)) return(NULL)
  wages <- ref$by_company[[company]]
  if (is.null(wages) || length(wages) == 0L) return(NULL)
  round(100 * mean(wages <= wage), 1)
}

# ---- history (section 5.2 HistoryPoint) -----------------------------------

# Cumulative earnings after each decision. `n_steps` limits how much of the
# story is revealed: the live state only shows steps up to the player's own
# decision count (the other trajectories are revealed progressively), while
# /share-data and Results show every step of every trajectory.
history_points <- function(user, policy, baseline, n_steps = NULL) {
  cumulative <- function(d) {
    if (is.null(d) || nrow(d) == 0L) return(numeric(0))
    pays <- ifelse(d$accepted %in% TRUE, d$driver_pay + d$tips, 0)
    cumsum(pays)
  }
  cu <- cumulative(user)
  cp <- cumulative(policy)
  cb <- cumulative(baseline)
  n <- if (is.null(n_steps)) {
    max(length(cu), length(cp), length(cb))
  } else {
    as.integer(n_steps)
  }
  pick <- function(v, k) {
    if (k == 0L || length(v) == 0L) return(0)
    v[[min(k, length(v))]]
  }
  step <- 0:n
  data.frame(
    step = as.integer(step),
    user = vapply(step, function(k) round(pick(cu, k), 2), numeric(1)),
    policy = vapply(step, function(k) round(pick(cp, k), 2), numeric(1)),
    baseline = vapply(step, function(k) round(pick(cb, k), 2), numeric(1)),
    stringsAsFactors = FALSE
  )
}

# ---- share copy (sections 6.6, 7.1) ---------------------------------------

# Big PNG/Results label for the verdict.
outcome_label <- function(outcome, seed_is_custom = FALSE) {
  if (isTRUE(seed_is_custom)) return("I simulated my own day")
  switch(
    outcome,
    beat_model = "I beat the Model!",
    tied_model = "I matched the Model",
    beat_baseline = "I beat the Baseline!",
    lost_to_baseline = "The Model won",
    no_rides = "No rides, no pay",
    "I simulated my own day"
  )
}

# Default share copy (contract ShareDataResponse.share_text): exactly what the
# UI pre-fills in the share box and what the share page puts in og:description,
# i.e. the one line of the section-6.6 table -- never the PNG context line.
outcome_share_text <- function(outcome, seed_is_custom = FALSE) {
  if (isTRUE(seed_is_custom)) {
    return("I just simulated a full day as an NYC taxi driver and compared myself to an XGBoost model. Try it yourself \U0001F695\U0001F4CA")
  }
  switch(
    outcome,
    beat_model = "I beat the model today. \U0001F695\U0001F4CA",
    tied_model = paste0(
      "I just matched the XGBoost policy over a simulated 8-hour NYC taxi shift. ",
      "Can you beat it? \U0001F695\U0001F4CA"
    ),
    beat_baseline = paste0(
      "I just simulated a full day as an NYC taxi driver. I couldn't beat the model, ",
      "but I beat the baseline. Can you? \U0001F695\U0001F4CA"
    ),
    lost_to_baseline = paste0(
      "I simulated 8 hours as an NYC taxi driver and did worse than simply ",
      "accepting every ride. Harder than it looks. \U0001F4C9\U0001F695"
    ),
    no_rides = paste0(
      "I simulated an NYC taxi shift by rejecting every ride. ",
      "Earnings: $0. Can you do better? \U0001F695"
    ),
    ""
  )
}

# Visible context paragraph of the share page (under the PNG). Not part of the
# API contract: the share service renders it from the outcome itself.
outcome_context_line <- function(outcome, seed_is_custom = FALSE) {
  if (isTRUE(seed_is_custom)) {
    return("This day used a custom seed and is marked unofficial.")
  }
  switch(
    outcome,
    beat_model = "You earned more per hour than the XGBoost policy in this simulated shift.",
    tied_model = "You matched the XGBoost policy per hour over this simulated shift.",
    beat_baseline = "You could not beat the model, but you beat accepting every ride.",
    lost_to_baseline = "Accepting every ride would have paid more per hour.",
    no_rides = "You rejected every ride, so the shift paid nothing.",
    ""
  )
}
