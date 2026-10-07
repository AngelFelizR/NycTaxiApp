# simulate_day (master doc section 3): the rules of the day, on planted data
# and with the deterministic policy of helper-sim.R.

test_that("the three trajectories are deterministic for a given seed", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    start <- sim_start_datetime()
    a <- simulate_day(42, "HV0005", start, 61L, "policy")
    b <- simulate_day(42, "HV0005", start, 61L, "policy")
    expect_identical(a$decisions, b$decisions)
    expect_identical(a$clock, b$clock)

    # A different seed walks a different (but equally valid) day.
    other <- simulate_day(43, "HV0005", start, 61L, "policy")
    expect_false(identical(a$decisions$trip_id, other$decisions$trip_id))
  })
})

test_that("the shift ends inside 8h30 and the break is taken once", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    start <- sim_start_datetime()
    sim <- simulate_day(42, "HV0005", start, 61L, "policy")
    expect_true(sim$ended)
    expect_null(sim$pending)
    expect_true(sim$taken_break)
    # A trip requested inside the window may finish after the limit.
    expect_lte(
      as.numeric(difftime(sim$clock, start, units = "mins")),
      SIM_SHIFT_HOURS * 60 + SIM_BREAK_MINUTES + 60
    )
    expect_gt(nrow(sim$decisions), 0L)
    expect_null(sim$error)
    # The break is not spent at the start of the day.
    expect_gt(as.numeric(difftime(sim$clock, start, units = "hours")), 4)
  })
})

test_that("baseline accepts everything, policy follows the recommendation", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  # with_accept_all_policy takes an expression, so the two mocks are siblings
  # in this frame rather than nested. Nesting them used to work only because
  # assign() into globalenv is order-independent; with local_mocked_bindings
  # the outer frame restores first and the inner restore then tries to write a
  # binding that is already locked again ("cannot change value of locked
  # binding").
  start <- sim_start_datetime()
  base <- with_accept_all_policy(
    simulate_day(7, "HV0005", start, 61L, "baseline")
  )
  expect_true(all(base$decisions$accepted))
  expect_true(all(base$decisions$model_recommended))

  # Same day, a policy that never recommends: nothing is accepted.
  local_mocked_bindings(
    policy_probability = function(frame) rep(0.1, nrow(frame)),
    .package = "taxiapi"
  )
  pol <- simulate_day(7, "HV0005", start, 61L, "policy")
  expect_false(any(pol$decisions$accepted))
  expect_true(all(pol$decisions$model_recommended == FALSE))
  expect_equal(wage_per_hour(pol$decisions), 0)
})

test_that("the WAV rule only offers non-WAV trips", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    sim <- simulate_day(11, "HV0005", sim_start_datetime(), 61L, "baseline")
    expect_gt(nrow(sim$decisions), 0L)
    # Every 5th planted trip is WAV and must never appear in a trajectory.
    expect_false(any(sim$decisions$trip_id %% 5 == 0))
  })
})

test_that("the company filter only offers the day's company", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    lyft <- simulate_day(3, "HV0005", sim_start_datetime(), 61L, "baseline")
    expect_gt(nrow(lyft$decisions), 0L)

    # The planted week has no Uber trip at all: the day ends empty.
    uber <- simulate_day(3, "HV0003", sim_start_datetime(), 61L, "baseline")
    expect_identical(nrow(uber$decisions), 0L)
    expect_true(uber$ended)
    expect_equal(wage_per_hour(uber$decisions), 0)
  })
})

test_that("user mode offers the first undecided trip as pending", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    start <- sim_start_datetime()
    fresh <- simulate_day(5, "HV0005", start, 61L, "user")
    expect_identical(nrow(fresh$decisions), 0L)
    expect_false(fresh$ended)
    expect_true(is.data.frame(fresh$pending))
    expect_identical(fresh$clock, start)
    expect_identical(fresh$position, 61L)
  })
})

test_that("a replay reproduces the stored decisions and stops at the gap", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    start <- sim_start_datetime()
    first <- simulate_day(9, "HV0005", start, 61L, "user")$pending
    stored <- decision_row(1, first, TRUE, TRUE)
    second <- simulate_day(9, "HV0005", start, 61L, "user",
                           recorded = stored)$pending
    stored <- rbind(stored, decision_row(2, second, FALSE, TRUE))
    sim <- simulate_day(9, "HV0005", start, 61L, "user", recorded = stored)
    expect_identical(nrow(sim$decisions), 2L)
    expect_identical(sim$decisions$trip_id, stored$trip_id)
    expect_identical(sim$decisions$accepted, c(TRUE, FALSE))
    expect_true(is.data.frame(sim$pending))
    expect_false(sim$ended)
  })
})

test_that("rejecting everything advances the clock 5 minutes per decision", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy({
    start <- sim_start_datetime()
    stored <- empty_decisions()
    n <- 0L
    repeat {
      sim <- simulate_day(42, "HV0005", start, 61L, "user", recorded = stored)
      if (is.null(sim$pending) || n >= 200L) break
      n <- n + 1L
      stored <- rbind(stored, decision_row(n, sim$pending, FALSE, TRUE))
    }
    expect_true(sim$ended)
    expect_gt(nrow(stored), 2L)
    expect_equal(trips_count(stored, FALSE), nrow(stored))
    # Every rejection costs SIM_DECLINE_WAIT_MIN of clock before the next
    # request can even exist, so a rejection can never leave the search
    # window inverted (section 3.8). The first offer has no penalty before
    # it, so only the gaps between requests are measured.
    gaps <- diff(as.numeric(stored$request_datetime))
    expect_true(all(gaps >= SIM_DECLINE_WAIT_MIN * 60 - 1e-6))
    expect_equal(wage_per_hour(stored), 0)
  })
})

test_that("candidate_trips honours company, WAV and distance", {
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  window <- list(
    current_time = as.POSIXct("2024-05-12 08:00:00", tz = "UTC"),
    time_limit = as.POSIXct("2024-05-12 08:01:00", tz = "UTC"),
    last_limit = as.POSIXct("2024-05-12 16:30:00", tz = "UTC")
  )
  cands <- candidate_trips(61L, "HV0005", window$current_time,
                           window$time_limit, window$last_limit, 1)
  expect_gt(nrow(cands), 0L)
  expect_true(all(cands$hvfhs_license_num == "HV0005"))
  expect_true(all(cands$wav_match_flag == "N"))

  none <- candidate_trips(61L, "HV0003", window$current_time,
                          window$time_limit, window$last_limit, 1)
  expect_identical(nrow(none), 0L)
})
