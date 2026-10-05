# outcome.R (sections 3.9, 3.10, 4.6, 6.6): wages, verdict, percentiles,
# history and share copy -- pure functions, no database and no model.

mk_decisions <- function(accepted, recommended = accepted) {
  n <- length(accepted)
  start <- as.POSIXct("2024-05-12 08:00:00", tz = "UTC")
  data.frame(
    step = seq_len(n),
    trip_id = seq_len(n),
    accepted = accepted,
    model_recommended = recommended,
    trip_miles = rep(3, n),
    trip_time = rep(600L, n),
    driver_pay = rep(20, n),
    tips = rep(1, n),
    pu_location_id = rep(61L, n),
    do_location_id = rep(161L, n),
    request_datetime = start + 600 * (seq_len(n) - 1),
    dropoff_datetime = start + 600 * seq_len(n),
    stringsAsFactors = FALSE
  )
}

test_that("wage is earnings over the fixed 8-hour shift", {
  expect_equal(day_earnings(NULL), 0)
  expect_equal(day_earnings(mk_decisions(logical(0))), 0)
  # Three accepted trips: 3 * ($20 + $1) = $63 over 8h = $7.88/h.
  d <- mk_decisions(c(TRUE, TRUE, TRUE))
  expect_equal(day_earnings(d), 63)
  expect_equal(wage_per_hour(d), 7.88)
  # Rejected trips pay nothing even though they carry a pay column.
  expect_equal(day_earnings(mk_decisions(c(TRUE, FALSE, FALSE))), 21)
})

test_that("outcome precedence matches section 3.10", {
  expect_identical(compute_outcome(10, 10, 10, 0L), "no_rides")
  expect_identical(compute_outcome(30, 20, 15, 5L), "beat_model")
  # The 0.01 tolerance keeps wages that differ by a cent from looking like
  # a win (the wages are rounded before they get here).
  expect_identical(compute_outcome(20.005, 20, 15, 5L), "tied_model")
  expect_identical(compute_outcome(20, 20, 15, 5L), "tied_model")
  expect_identical(compute_outcome(19.99, 25, 19.98, 5L), "beat_baseline")
  expect_identical(compute_outcome(10, 20, 20, 5L), "lost_to_baseline")
  # no_rides wins even when the wages would say otherwise.
  expect_identical(compute_outcome(0, 0, 0, 0L), "no_rides")
})

test_that("pct_following_policy is the match rate and reads 100 when empty", {
  expect_identical(pct_following_policy(NULL), 100)
  expect_identical(pct_following_policy(mk_decisions(logical(0))), 100)
  # The player took 3 of the 4 offers the model pointed at.
  expect_identical(
    pct_following_policy(mk_decisions(c(TRUE, TRUE, FALSE, TRUE),
                                      recommended = c(TRUE, TRUE, TRUE, TRUE))),
    75
  )
  expect_identical(
    pct_following_policy(mk_decisions(c(TRUE, FALSE), recommended = c(NA, NA))),
    100
  )
})

test_that("trips_count splits accepted from rejected", {
  d <- mk_decisions(c(TRUE, FALSE, TRUE, FALSE, FALSE))
  expect_identical(trips_count(d, TRUE), 2L)
  expect_identical(trips_count(d, FALSE), 3L)
  expect_identical(trips_count(NULL, TRUE), 0L)
})

test_that("history is progressive live and complete at the end", {
  user <- mk_decisions(c(TRUE, FALSE))
  policy <- mk_decisions(c(TRUE, TRUE, TRUE))
  baseline <- mk_decisions(c(TRUE, TRUE))

  live <- history_points(user, policy, baseline, n_steps = nrow(user))
  expect_identical(live$step, 0:2)
  expect_equal(live$user, c(0, 21, 21))
  # Curves are revealed by step: nothing beyond the player's own decisions.
  expect_equal(live$policy, c(0, 21, 42))
  expect_equal(live$baseline, c(0, 21, 42))

  full <- history_points(user, policy, baseline)
  expect_identical(full$step, 0:3)
  expect_equal(full$user, c(0, 21, 21, 21))
  expect_equal(full$policy, c(0, 21, 42, 63))
  expect_equal(full$baseline, c(0, 21, 42, 42))

  # A fresh experiment has nothing to show but the origin.
  fresh <- history_points(mk_decisions(logical(0)), policy, baseline,
                          n_steps = 0L)
  expect_identical(nrow(fresh), 1L)
  expect_identical(fresh$step, 0L)
  expect_equal(fresh$user, 0)
})

test_that("share copy follows the section 6.6 table", {
  expect_identical(outcome_label("beat_model"), "I beat the Model!")
  expect_identical(outcome_label("tied_model"), "I matched the Model")
  expect_identical(outcome_label("beat_baseline"), "I beat the Baseline!")
  expect_identical(outcome_label("lost_to_baseline"), "The Model won")
  expect_identical(outcome_label("no_rides"), "No rides, no pay")

  expect_identical(outcome_share_text("beat_model"), "I beat the model today. \U0001F695\U0001F4CA")
  expect_match(outcome_share_text("tied_model"), "matched the XGBoost policy")
  expect_match(outcome_share_text("beat_baseline"), "beat the baseline")
  expect_match(outcome_share_text("lost_to_baseline"), "Harder than it looks")
  expect_match(outcome_share_text("no_rides"), "rejecting every ride")

  # Custom seeds never get a victory line (section 3, rule 3).
  expect_identical(outcome_label("beat_model", seed_is_custom = TRUE),
                   "I simulated my own day")
  expect_false(grepl("beat the model", outcome_share_text("beat_model", TRUE)))
})

test_that("reference percentile ranks the wage inside the company", {
  old <- model_state$reference
  on.exit(model_state$reference <- old, add = TRUE)
  model_state$reference <- list(
    by_company = list(Lyft = c(10, 20, 30, 40), Uber = c(15, 25, 35))
  )
  expect_equal(reference_percentile("Lyft", 30), 75)
  expect_equal(reference_percentile("Lyft", 40), 100)
  expect_equal(reference_percentile("Uber", 10), 0)
  # Unknown company or missing file: NULL, never a made-up number.
  expect_null(reference_percentile("Via", 30))

  model_state$reference <- NULL
  ref_path <- file.path(models_dir(), "ReferenceDistribution.qs2")
  if (file.exists(ref_path)) skip("ReferenceDistribution.qs2 is installed")
  expect_null(reference_percentile("Lyft", 30))
})
