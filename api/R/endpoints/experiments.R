# Experiments (contract operations createExperiment, getExperiment,
# getExperimentState, createDecision, finishExperiment, addFeedback,
# abandonExperiment -- master doc sections 5.2, 3).
#
# The day is never stored as a simulation: only the decision tables are
# written and everything else -- clock, position, next trip, curves -- is
# replayed from them with the same seed, which is what makes
# POST /experiments/{id}/decisions idempotent and the resume code portable
# (section 5.2).
#
# POST /experiments answers as soon as the experiment row and the player's
# first offer exist (status "setup"): policy and baseline are computed in a
# forked child and the experiment flips to "in_progress" when both are stored
# (see start_background_trajectories()). The master doc describes the three
# trajectories as pre-computed before the response; the contract records the
# divergence (201 -> setup -> in_progress).

UUID_PATTERN <-
  "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

# 16 random bytes -> 22 chars (resume code), 9 -> 12 chars (share token),
# both unpadded base64url as the contract documents.
#
# The bytes come from the OS entropy pool, never from the ambient R RNG:
# simulate_day() seeds that RNG from the experiment seed, so a code drawn
# from it would be a function of the seed (guessable, section 5.2) and two
# days with the same seed would collide on experiments_resume_code_hash.
random_base64url <- function(n_bytes) {
  bytes <- if (file.exists("/dev/urandom")) {
    tryCatch(suppressWarnings({
      con <- file("/dev/urandom", open = "rb")
      on.exit(close(con))
      readBin(con, what = "raw", n = n_bytes)
    }), error = function(e) NULL)
  } else {
    NULL
  }
  if (is.null(bytes) || length(bytes) != n_bytes) {
    bytes <- as.raw(sample.int(256L, n_bytes, replace = TRUE) - 1L)
  }
  encoded <- jsonlite::base64_enc(bytes)
  encoded <- chartr("+/", "-_", encoded)
  sub("=+$", "", encoded)
}

resume_hash <- function(resume_code) {
  digest::digest(resume_code, algo = "sha256", serialize = FALSE)
}

# ---- shared helpers --------------------------------------------------------

# Loads the experiment behind X-Resume-Code. Returns list(ok, experiment) or
# list(ok = FALSE, fail = <plumber2 Break>) with the response already set.
auth_experiment <- function(request, response, id) {
  fail <- function(status, error, message) {
    list(ok = FALSE, fail = api_error(response, status, error, message))
  }
  if (!is_string(id) || !grepl(UUID_PATTERN, id)) {
    return(fail(404L, "not_found", "Experiment not found."))
  }
  rows <- db_get_experiment(id)
  if (is.null(rows)) return(fail(503L, "service_unavailable", "Database unavailable."))
  exp <- first_row(rows)
  if (is.null(exp)) return(fail(404L, "not_found", "Experiment not found."))
  code <- request$get_header("x-resume-code")
  if (is.null(code) || !is.character(code) || length(code) != 1L || !nzchar(code)) {
    return(fail(403L, "forbidden", "Invalid or missing X-Resume-Code header."))
  }
  # secure_equal() hashes both arguments, so the header code has to be hashed
  # first: the column already stores a digest (internal_auth.R).
  if (!secure_equal(resume_hash(code), exp$resume_code_hash)) {
    return(fail(403L, "forbidden", "Invalid or missing X-Resume-Code header."))
  }
  list(ok = TRUE, experiment = exp)
}

# Stored decisions of one trajectory (NULL = database error).
load_trajectory <- function(experiment_id, source) db_get_decisions(experiment_id, source)

# Replays the player's trajectory. NULL = database error; $error marks a
# simulator failure (model gone mid-day).
replay_user <- function(exp, stored = NULL) {
  recorded <- if (is.null(stored)) load_trajectory(exp$id, "user") else stored
  if (is.null(recorded)) return(NULL)
  simulate_day(
    seed = exp$seed,
    company_code = company_to_hvfhs(exp$company),
    start_datetime = exp$start_datetime,
    start_location_id = exp$start_location_id,
    mode = "user",
    recorded = recorded
  )
}

# Next ride offered to the player, with the model's opinion on it.
build_trip_body <- function(trip) {
  probability <- tryCatch(
    policy_probability(policy_frame(trip)),
    error = function(e) NULL
  )
  if (is.null(probability) || length(probability) != 1L || is.na(probability)) {
    return(structure(list(), class = "trip_unavailable"))
  }
  list(
    trip_id = as.numeric(trip$trip_id),
    pulocation_id = as.integer(trip$PULocationID),
    dolocation_id = as.integer(trip$DOLocationID),
    pickup_zone = zone_display(trip$PULocationID),
    dropoff_zone = zone_display(trip$DOLocationID),
    miles = round(as.numeric(trip$trip_miles), 1),
    trip_time_sec = as.integer(trip$trip_time),
    driver_pay = as.numeric(trip$driver_pay),
    tips = as.numeric(trip$tips),
    request_datetime = iso_utc(trip$request_datetime),
    recommendation = if (probability > policy_threshold) "accept" else "reject",
    probability = round(probability, 4)
  )
}

result_body <- function(exp, user) {
  if (!identical(exp$status, "finished")) return(NA)
  list(
    final_user_wage = as.numeric(exp$final_user_wage),
    final_policy_wage = as.numeric(exp$final_policy_wage),
    final_baseline_wage = as.numeric(exp$final_baseline_wage),
    pct_following_policy = as.numeric(exp$pct_following_policy),
    outcome = as.character(exp$outcome),
    user_percentile = as.numeric(exp$user_percentile),
    trips_accepted = trips_count(user, TRUE),
    trips_rejected = trips_count(user, FALSE)
  )
}

feedback_body <- function(exp) {
  if (is.null(exp$feedback_rating) || is.na(exp$feedback_rating)) return(NA)
  comment <- exp$feedback_comment
  list(
    rating = as.integer(exp$feedback_rating),
    comment = if (is.null(comment) || is.na(comment)) NA else as.character(comment),
    public = isTRUE(exp$feedback_public)
  )
}

experiment_body <- function(exp, user = NULL) {
  if (is.null(user)) user <- load_trajectory(exp$id, "user")
  if (is.null(user)) user <- empty_decisions()
  list(
    id = as.character(exp$id),
    status = as.character(exp$status),
    company = as.character(exp$company),
    start_datetime = iso_utc(exp$start_datetime),
    start_location_id = as.integer(exp$start_location_id),
    seed = as.numeric(exp$seed),
    seed_is_custom = isTRUE(exp$seed_is_custom),
    model_version = as.character(exp$model_version),
    app_version = as.character(exp$app_version),
    created_at = iso_utc(exp$created_at),
    updated_at = iso_utc(exp$updated_at),
    finished_at = if (is.null(exp$finished_at) || is.na(exp$finished_at)) {
      NA
    } else {
      iso_utc(exp$finished_at)
    },
    share_token = as.character(exp$share_token),
    result = result_body(exp, user),
    feedback = feedback_body(exp)
  )
}

# Approximate progress (0-99) reported while the background job runs. The
# field is dropped as soon as the experiment leaves "setup", so 100 is implied
# by status rather than by the number: policy days run 0-94 by row count,
# the baseline batch (written at once) lands at 99 until the flip.
model_progress <- function(policy, baseline) {
  if (nrow(baseline) > 0L) return(99L)
  if (nrow(policy) == 0L) return(0L)
  as.integer(min(94L, round(94 * nrow(policy) / EXPECTED_POLICY_STEPS)))
}

# DayState shared by POST /experiments, GET /state and POST /decisions.
# `sim` is the replayed player trajectory (its pending offer is the next trip).
build_state_body <- function(exp, sim, user, policy, baseline) {
  status <- as.character(exp$status)
  next_trip <- NA
  if (identical(status, "in_progress") && !is.null(sim$pending)) {
    trip <- build_trip_body(sim$pending)
    if (inherits(trip, "trip_unavailable")) {
      return(structure(list(), class = "state_unavailable"))
    }
    next_trip <- trip
  }
  clock <- sim$clock
  taken_break <- isTRUE(sim$taken_break)
  elapsed_hours <- as.numeric(difftime(clock, exp$start_datetime, units = "hours"))
  pending_hours <- round(max(0, SIM_SHIFT_HOURS - (elapsed_hours - 0.5 * as.numeric(taken_break))), 1)
  n_steps <- if (identical(status, "finished")) NULL else nrow(user)
  state <- list(
    experiment_id = as.character(exp$id),
    status = status,
    clock = format(clock, "%Y-%m-%d %H:%M:%S", tz = "UTC"),
    pending_hours = pending_hours,
    pct_following_policy = pct_following_policy(user),
    current_location_id = as.integer(sim$position),
    current_zone = zone_display(sim$position),
    next_trip = next_trip,
    history = history_points(user, policy, baseline, n_steps = n_steps),
    result = result_body(exp, user)
  )
  # Only while the model is still working: a NULL element would serialise as
  # "{}" instead of disappearing, so the key is added conditionally.
  if (identical(status, "setup")) {
    state$model_progress <- model_progress(policy, baseline)
  }
  state
}

# Loads the three trajectories (policy and baseline from Postgres).
load_state_inputs <- function(exp, sim) {
  user <- sim$decisions
  policy <- load_trajectory(exp$id, "policy")
  baseline <- load_trajectory(exp$id, "baseline")
  if (is.null(policy) || is.null(baseline)) return(NULL)
  list(user = user, policy = policy, baseline = baseline)
}

# ---- background trajectories (status "setup") -----------------------------

# API_EXPERIMENTS_SYNC=1 runs the trajectories inside the request (the
# behaviour the contract described before the create endpoint went async, and
# what the test suite uses so assertions never race a forked child).
experiments_sync <- function() {
  identical(trimws(Sys.getenv("API_EXPERIMENTS_SYNC", "0")), "1")
}

# Typical length of a policy day; only used to turn "rows already persisted"
# into the approximate model_progress reported while status is setup.
EXPECTED_POLICY_STEPS <- 60L

# A background job that never finishes (a fork that deadlocked, a model that
# stopped answering) would leave the day in setup forever, so after this many
# seconds the row is retired and the client gets a 503 instead of an endless
# spinner. A healthy run takes 10-20s.
SETUP_TIMEOUT_S <- 120

setup_timed_out <- function(exp) {
  age <- as.numeric(difftime(Sys.time(), exp$created_at, units = "secs"))
  is.finite(age) && age > SETUP_TIMEOUT_S
}

# mcparallel children only leave the process table once they are collected,
# and a child lingers in its exit path after the work because it inherited the
# server's libuv state, so jobs are reaped on every /state poll and before a
# new fork. wait=FALSE so a child that is still computing never blocks a
# request; anything left running past SETUP_TIMEOUT_S is killed.
reap_trajectory_jobs <- function() {
  jobs <- model_state$traj_jobs
  if (length(jobs) == 0L) return(invisible(NULL))
  ready <- tryCatch(
    # A child that vanished (already reaped elsewhere) makes mccollect warn;
    # the liveness check below drops the job either way.
    suppressWarnings(
      parallel::mccollect(lapply(jobs, `[[`, "job"), wait = FALSE)
    ),
    error = function(e) NULL
  )
  keep <- vapply(names(jobs), function(pid) {
    alive <- isTRUE(tryCatch(tools::pskill(as.integer(pid), 0L),
                             error = function(e) FALSE))
    if (!alive) return(FALSE)
    age <- as.numeric(difftime(Sys.time(), jobs[[pid]]$started,
                               units = "secs"))
    if (age > SETUP_TIMEOUT_S) {
      try(tools::pskill(as.integer(pid), 9L), silent = TRUE)
      return(FALSE)
    }
    TRUE
  }, logical(1))
  model_state$traj_jobs <- jobs[keep]
  if (length(ready) > 0L) {
    cat("trajectories: collected ", length(ready), " job(s), ", sum(keep),
        " pending\n", sep = "", file = stderr())
  }
  invisible(NULL)
}

# Persists a trajectory while it is being simulated: the first
# `chunked_steps` decisions land in chunks of `chunk_size` (a client polling
# /state watches the day take shape instead of staring at a spinner), the
# rest is flushed in one batch when the simulation ends.
trajectory_writer <- function(experiment_id, source, chunk_size = 5L,
                              chunked_steps = 20L,
                              write = db_insert_decisions) {
  written <- 0L
  function(decisions, flush = FALSE) {
    n <- if (is.null(decisions) || nrow(decisions) == 0L) 0L else nrow(decisions)
    if (n <= written) return(invisible(written))
    if (!flush && (n > chunked_steps || n %% chunk_size != 0L)) {
      return(invisible(written))
    }
    stored <- write(experiment_id, source, decisions[(written + 1L):n, , drop = FALSE])
    # A lost write would leave a half trajectory behind, so stop the
    # simulation: the caller retires the experiment instead of promoting it.
    if (is.null(stored)) {
      stop("failed to persist ", source, " decisions (database error)")
    }
    written <<- n
    invisible(written)
  }
}

# Computes policy + baseline for an experiment in "setup" and flips it to
# "in_progress". Runs either inline (API_EXPERIMENTS_SYNC=1 or no fork
# available) or in a forked child.
#
# `isolated` marks the forked case: the child must not use the inherited pool,
# those connections belong to the API process, so it opens its own and swaps
# it into model_state (a private copy thanks to copy-on-write). Inline runs
# keep the pool they already have.
compute_trajectories <- function(exp, isolated = TRUE) {
  t0 <- proc.time()[["elapsed"]]
  own_pool <- if (isolated) create_db_pool() else NULL
  if (isolated && is.null(own_pool)) {
    cat("trajectories: no database connection for ", exp$id, "\n", file = stderr())
    return(FALSE)
  }
  parent_pool <- model_state$pool
  if (isolated) model_state$pool <- own_pool
  on.exit({
    if (isolated) {
      model_state$pool <- parent_pool
      try(pool::poolClose(own_pool), silent = TRUE)
    }
  }, add = TRUE)

  code <- company_to_hvfhs(as.character(exp$company))
  policy_writer <- trajectory_writer(exp$id, "policy")
  # Baseline is stored in one batch: its model_recommended column is NOT NULL
  # and is only known once the whole day has been predicted in bulk, so
  # streaming it would mean writing either NAs or a different trajectory.
  baseline_writer <- trajectory_writer(exp$id, "baseline")

  ok <- tryCatch({
    sim_policy <- simulate_day(
      exp$seed, code, exp$start_datetime, exp$start_location_id, "policy",
      on_step = policy_writer
    )
    if (!is.null(sim_policy$error)) stop("policy: ", sim_policy$error)
    policy_writer(sim_policy$decisions, flush = TRUE)

    sim_baseline <- simulate_day(
      exp$seed, code, exp$start_datetime, exp$start_location_id, "baseline"
    )
    if (!is.null(sim_baseline$error)) stop("baseline: ", sim_baseline$error)
    baseline_writer(sim_baseline$decisions, flush = TRUE)
    TRUE
  }, error = function(e) {
    cat("trajectories failed for ", exp$id, ": ", conditionMessage(e), "\n",
        file = stderr())
    FALSE
  })

  if (!ok) {
    db_abandon_experiment(exp$id)
    return(FALSE)
  }
  ready <- db_mark_trajectories_ready(exp$id)
  if (is.null(ready)) {
    cat("trajectories: could not promote ", exp$id, "\n", file = stderr())
    return(FALSE)
  }
  cat(sprintf(
    "experiment ready: id=%s policy=%d baseline=%d in %.1fs\n",
    exp$id, nrow(sim_policy$decisions), nrow(sim_baseline$decisions),
    proc.time()[["elapsed"]] - t0
  ), file = stderr())
  TRUE
}

# Forks the computation so the request can answer immediately. A fork starts
# with the models and the trip data already in memory (copy-on-write), which
# is what keeps the wait invisible to the player; if forking is unavailable we
# fall back to the synchronous behaviour rather than leaving the day stuck.
start_background_trajectories <- function(exp) {
  if (experiments_sync()) return(compute_trajectories(exp, isolated = FALSE))
  reap_trajectory_jobs()
  job <- tryCatch(
    parallel::mcparallel({
      # The job's result is only read by mccollect(), which a request never
      # calls, so an error escaping compute_trajectories() would be invisible:
      # the child logs it itself, before and after the work.
      cat("trajectories: child pid ", Sys.getpid(), " start for ", exp$id,
          "\n", file = stderr())
      ok <- tryCatch(
        compute_trajectories(exp, isolated = TRUE),
        error = function(e) {
          cat("trajectories: child pid ", Sys.getpid(), " failed: ",
              conditionMessage(e), "\n", file = stderr())
          FALSE
        }
      )
      cat("trajectories: child pid ", Sys.getpid(), " done=", ok, "\n",
          file = stderr())
      ok
    }),
    error = function(e) {
      cat("trajectories: fork failed (", conditionMessage(e),
          "), computing inline\n", file = stderr())
      NULL
    }
  )
  if (is.null(job)) return(compute_trajectories(exp, isolated = FALSE))
  model_state$traj_jobs[[as.character(job$pid)]] <-
    list(job = job, started = Sys.time())
  cat("trajectories: forked pid ", job$pid, " for ", exp$id, "\n",
      file = stderr())
  TRUE
}

# ---- POST /experiments -----------------------------------------------------

create_experiment_handler <- function(request, response, body) {
  t_start <- proc.time()[["elapsed"]]
  if (!isTRUE(models_status()$policy)) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }
  if (!trip_data_ready()) {
    return(api_error(response, 503L, "service_unavailable", "Trip data is not loaded."))
  }
  if (is.null(db_pool()) || !schema_ready()) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  ip_hash <- client_ip_hash(request)
  limited <- rate_limit_check(
    request, response, "exp", 3L,
    "You've reached the limit of 3 experiments per day."
  )
  if (!is.null(limited)) return(limited)

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }
  absent <- missing_fields(payload, c("company", "start_datetime", "start_location_id"))
  if (length(absent) > 0) {
    return(api_error(
      response, 400L, "bad_request",
      paste0("Missing required field(s): ", paste(absent, collapse = ", "), ".")
    ))
  }
  if (!valid_company(payload$company)) {
    return(api_error(response, 400L, "bad_request", "company must be one of: Lyft, Uber."))
  }
  if (!is_string(payload$start_datetime)) {
    return(api_error(response, 400L, "bad_request", "start_datetime must be a string."))
  }
  start_datetime <- lubridate::ymd_hms(payload$start_datetime, tz = "UTC", quiet = TRUE)
  if (is.na(start_datetime)) {
    return(api_error(response, 400L, "bad_request", "start_datetime must be ISO 8601."))
  }
  if (!is_wholenumber(payload$start_location_id)) {
    return(api_error(response, 400L, "bad_request", "start_location_id must be an integer."))
  }
  if (payload$start_location_id < 1 || payload$start_location_id > N_ZONES) {
    return(api_error(
      response, 422L, "unprocessable_entity", "start_location_id must be between 1 and 265."
    ))
  }
  if (is.null(zone_info(payload$start_location_id))) {
    return(api_error(
      response, 422L, "unprocessable_entity",
      "start_location_id is not a TLC zone with trip data."
    ))
  }

  seed <- NULL
  if (!is.null(payload$seed)) {
    if (!is_wholenumber(payload$seed)) {
      return(api_error(response, 400L, "bad_request", "seed must be an integer."))
    }
    if (payload$seed < 0 || payload$seed > 9007199254740991) {
      return(api_error(
        response, 422L, "unprocessable_entity",
        "seed must be between 0 and 9007199254740991."
      ))
    }
    seed <- payload$seed
  }
  email <- payload$email
  if (!is.null(email)) {
    if (!is_email(email)) {
      return(api_error(
        response, 422L, "unprocessable_entity", "email must be a valid email address."
      ))
    }
  }
  if (!is.null(payload$marketing_consent) &&
    !(is.logical(payload$marketing_consent) && length(payload$marketing_consent) == 1L)) {
    return(api_error(response, 400L, "bad_request", "marketing_consent must be a boolean."))
  }

  # The whole shift must fit inside the simulated week.
  range <- trip_data_range()
  shift_end <- start_datetime + (SIM_SHIFT_HOURS * 3600 + SIM_BREAK_MINUTES * 60)
  if (is.null(range) || start_datetime < range[[1]] || shift_end > range[[2]]) {
    return(api_error(
      response, 422L, "unprocessable_entity",
      sprintf(
        "start_datetime must leave the whole 8h30 shift inside %s .. %s.",
        format(range[[1]], "%Y-%m-%d %H:%M", tz = "UTC"),
        format(range[[2]], "%Y-%m-%d %H:%M", tz = "UTC")
      )
    ))
  }

  seed_is_custom <- !is.null(seed)
  if (is.null(seed)) seed <- sample.int(.Machine$integer.max, 1L)
  resume_code <- random_base64url(16L)
  share_token <- random_base64url(9L)
  company_code <- company_to_hvfhs(payload$company)
  location_id <- as.integer(payload$start_location_id)

  participant <- db_participant_upsert(
    email = if (is.null(email)) NULL else email,
    marketing_consent = isTRUE(payload$marketing_consent),
    ip_hash = ip_hash,
    country = client_country(request)
  )

  t_sim <- proc.time()[["elapsed"]]
  # The player's own trajectory makes no model calls (it stops at the first
  # offer), so it is cheap and gives the response a real next trip. Policy and
  # baseline -- the ~20s part -- are computed by start_background_trajectories().
  sim_user <- simulate_day(seed, company_code, start_datetime, location_id, "user")
  if (!is.null(sim_user$error)) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }
  sim_ms <- round((proc.time()[["elapsed"]] - t_sim) * 1000)

  created <- db_insert_experiment(
    participant_id = if (is.null(participant)) NULL else participant$id,
    resume_code_hash = resume_hash(resume_code),
    share_token = share_token,
    seed = seed,
    seed_is_custom = seed_is_custom,
    company = payload$company,
    start_datetime = start_datetime,
    start_location_id = location_id,
    model_version = Sys.getenv("MODEL_VERSION", "0.0.1-data"),
    app_version = Sys.getenv("APP_VERSION", "0.1.0"),
    status = "setup"
  )
  if (is.null(created)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  redis_incr("exp:started", ttl = NULL)

  exp <- db_get_experiment(created$id)
  exp <- first_row(exp)
  if (is.null(exp)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  start_background_trajectories(exp)

  # Re-read: under API_EXPERIMENTS_SYNC the trajectories already ran and the
  # experiment is in_progress, otherwise it is still setup.
  exp <- db_get_experiment(created$id)
  exp <- first_row(exp)
  if (is.null(exp)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  if (identical(exp$status, "abandoned")) {
    # Sync-mode failure: the trajectories could not be computed, so the day
    # never started and the player must not receive a resume code for it.
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }

  policy <- load_trajectory(created$id, "policy")
  baseline <- load_trajectory(created$id, "baseline")
  if (is.null(policy) || is.null(baseline)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  state <- build_state_body(exp, sim_user, sim_user$decisions, policy, baseline)
  if (inherits(state, "state_unavailable")) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }

  cat(sprintf(
    "experiment created: id=%s status=%s user=%d policy=%d baseline=%d user_sim=%dms total=%dms\n",
    as.character(exp$id), as.character(exp$status),
    nrow(sim_user$decisions), nrow(policy), nrow(baseline), sim_ms,
    round((proc.time()[["elapsed"]] - t_start) * 1000)
  ), file = stderr())

  response$status <- 201L
  # DayState already carries experiment_id: adding it again would emit the
  # key twice in the JSON object (CreatedExperiment = DayState + credentials).
  response$body <- c(
    state,
    list(
      resume_code = resume_code,
      share_token = as.character(exp$share_token)
    )
  )
  plumber2::Break
}

# ---- GET /experiments/{id} -------------------------------------------------

get_experiment_handler <- function(request, response, id) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  response$body <- experiment_body(auth$experiment)
  plumber2::Break
}

# ---- GET /experiments/{id}/state ------------------------------------------

get_state_handler <- function(request, response, id) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  exp <- auth$experiment

  # The UI polls /state while the model works, so this is where finished
  # children are collected and where a job that never finished gives up.
  reap_trajectory_jobs()
  if (identical(exp$status, "setup") && setup_timed_out(exp)) {
    db_abandon_experiment(exp$id)
    return(api_error(
      response, 503L, "service_unavailable",
      "The day could not be prepared. Please start again."
    ))
  }

  sim <- replay_user(exp)
  if (is.null(sim)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  inputs <- load_state_inputs(exp, sim)
  if (is.null(inputs)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  state <- build_state_body(exp, sim, inputs$user, inputs$policy, inputs$baseline)
  if (inherits(state, "state_unavailable")) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }
  response$body <- state
  plumber2::Break
}

# ---- POST /experiments/{id}/decisions -------------------------------------

create_decision_handler <- function(request, response, id, body) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  exp <- auth$experiment

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }
  absent <- missing_fields(payload, c("trip_id", "accepted"))
  if (length(absent) > 0) {
    return(api_error(
      response, 400L, "bad_request",
      paste0("Missing required field(s): ", paste(absent, collapse = ", "), ".")
    ))
  }
  if (!is_wholenumber(payload$trip_id)) {
    return(api_error(response, 400L, "bad_request", "trip_id must be an integer."))
  }
  if (!(is.logical(payload$accepted) && length(payload$accepted) == 1L)) {
    return(api_error(response, 400L, "bad_request", "accepted must be a boolean."))
  }

  stored <- load_trajectory(exp$id, "user")
  if (is.null(stored)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  # Idempotent retry: the trip is already among the stored decisions.
  hit <- if (nrow(stored) > 0L) which(stored$trip_id == as.numeric(payload$trip_id)) else integer(0)
  if (length(hit) > 0L) {
    if (isTRUE(as.logical(stored$accepted[hit[[1]]])) == isTRUE(payload$accepted)) {
      return(respond_state(exp, stored, response))
    }
    return(api_error(
      response, 409L, "conflict",
      "This trip was already decided with a different payload."
    ))
  }

  if (identical(exp$status, "setup")) {
    return(api_error(
      response, 409L, "conflict",
      "The day has not started yet."
    ))
  }
  if (!identical(exp$status, "in_progress")) {
    return(api_error(
      response, 409L, "conflict",
      "This experiment is not in progress."
    ))
  }

  sim <- replay_user(exp, stored = stored)
  if (is.null(sim)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  if (!is.null(sim$error)) {
    return(api_error(response, 500L, "internal_error", "Simulation replay failed."))
  }
  if (is.null(sim$pending)) {
    return(api_error(response, 409L, "conflict", "The day is already over."))
  }
  if (as.numeric(sim$pending$trip_id) != as.numeric(payload$trip_id)) {
    return(api_error(
      response, 409L, "conflict",
      "This trip was already decided with a different payload."
    ))
  }

  recommendation <- tryCatch(
    policy_probability(policy_frame(sim$pending)),
    error = function(e) NULL
  )
  if (is.null(recommendation) || length(recommendation) != 1L || is.na(recommendation)) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }

  step <- nrow(stored) + 1L
  row <- decision_row(step, sim$pending, payload$accepted, recommendation > policy_threshold)
  outcome <- db_insert_decision(
    exp$id, "user", row$step, row$trip_id, row$accepted, row$model_recommended,
    row$trip_miles, row$trip_time, row$driver_pay, row$tips,
    row$pu_location_id, row$do_location_id, row$request_datetime, row$dropoff_datetime
  )
  if (is.null(outcome)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  if (identical(outcome, "conflict")) {
    return(api_error(
      response, 409L, "conflict",
      "This trip was already decided with a different payload."
    ))
  }
  if (identical(outcome, "duplicate")) {
    stored <- load_trajectory(exp$id, "user")
    if (is.null(stored)) {
      return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
    }
    return(respond_state(exp, stored, response))
  }

  stored <- load_trajectory(exp$id, "user")
  if (is.null(stored)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  respond_state(exp, stored, response)
}

# DayState after a stored decision (also the idempotent-retry response).
respond_state <- function(exp, user, response) {
  sim <- replay_user(exp, stored = user)
  if (is.null(sim)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  inputs <- load_state_inputs(exp, sim)
  if (is.null(inputs)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  state <- build_state_body(exp, sim, inputs$user, inputs$policy, inputs$baseline)
  if (inherits(state, "state_unavailable")) {
    return(api_error(response, 503L, "service_unavailable", "Models are not loaded."))
  }
  response$body <- state
  plumber2::Break
}

# ---- POST /experiments/{id}/finish ----------------------------------------

finish_experiment_handler <- function(request, response, id) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  exp <- auth$experiment

  if (identical(exp$status, "setup")) {
    return(api_error(
      response, 409L, "conflict",
      "The day has not started yet."
    ))
  }

  user <- load_trajectory(exp$id, "user")
  policy <- load_trajectory(exp$id, "policy")
  baseline <- load_trajectory(exp$id, "baseline")
  if (is.null(user) || is.null(policy) || is.null(baseline)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  user_wage <- wage_per_hour(user)
  policy_wage <- wage_per_hour(policy)
  baseline_wage <- wage_per_hour(baseline)
  accepted <- trips_count(user, TRUE)
  outcome <- compute_outcome(user_wage, policy_wage, baseline_wage, accepted)
  percentile <- reference_percentile(as.character(exp$company), user_wage)
  if (is.null(percentile)) {
    return(api_error(
      response, 503L, "service_unavailable",
      "Reference distribution is not loaded."
    ))
  }

  updated <- db_finish_experiment(
    exp$id, user_wage, policy_wage, baseline_wage,
    pct_following_policy(user), outcome, percentile,
    accepted, trips_count(user, FALSE)
  )
  if (identical(updated, "conflict")) {
    return(api_error(
      response, 409L, "conflict",
      "This experiment has already finished."
    ))
  }
  if (is.null(updated)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  redis_incr("exp:finished", ttl = NULL)
  response$body <- experiment_body(updated, user = user)
  plumber2::Break
}

# ---- POST /experiments/{id}/feedback --------------------------------------

feedback_handler <- function(request, response, id, body) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  exp <- auth$experiment

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }
  absent <- missing_fields(payload, c("rating"))
  if (length(absent) > 0) {
    return(api_error(
      response, 400L, "bad_request",
      paste0("Missing required field(s): ", paste(absent, collapse = ", "), ".")
    ))
  }
  if (!is_wholenumber(payload$rating)) {
    return(api_error(response, 400L, "bad_request", "rating must be an integer."))
  }
  if (payload$rating < 1 || payload$rating > 5) {
    return(api_error(
      response, 422L, "unprocessable_entity", "rating must be between 1 and 5."
    ))
  }
  comment <- NULL
  if (!is.null(payload$comment)) {
    if (!is_string(payload$comment)) {
      return(api_error(response, 400L, "bad_request", "comment must be a string."))
    }
    comment <- payload$comment
  }
  if (!is.null(payload$public) &&
    !(is.logical(payload$public) && length(payload$public) == 1L)) {
    return(api_error(response, 400L, "bad_request", "public must be a boolean."))
  }

  ok <- db_update_feedback(exp$id, payload$rating, comment, isTRUE(payload$public))
  if (is.null(ok)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  response$body <- list(message = "Feedback saved.")
  plumber2::Break
}

# ---- POST /experiments/{id}/abandon ---------------------------------------

abandon_experiment_handler <- function(request, response, id) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  exp <- auth$experiment

  updated <- db_abandon_experiment(exp$id)
  if (identical(updated, "conflict")) {
    return(api_error(
      response, 409L, "conflict",
      "This experiment has already finished."
    ))
  }
  if (is.null(updated)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  redis_incr("exp:abandoned", ttl = NULL)
  response$body <- experiment_body(updated)
  plumber2::Break
}
