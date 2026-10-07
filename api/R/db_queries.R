# All Postgres access for phase 3 (sections 2.2, 5.1): participants,
# experiments, decisions and waitlist. Every call is wrapped in db_try() so a
# database outage surfaces as a NULL/sentinel that the handlers translate
# into the contract's 503 instead of a 500 with a stack trace.
#
# The pool object is itself a DBI connection (pool registers the DBI methods
# for class "Pool"), so it is passed straight to DBI::dbGetQuery and friends;
# there is no withPool() in pool >= 0.1.10. No clear IP is ever stored: the
# value arrives already hashed from client_ip.R.

db_try <- function(label, expr) {
  tryCatch(
    expr,
    error = function(e) {
      cat("db ", label, ": ", conditionMessage(e), "\n", file = stderr())
      NULL
    }
  )
}

db_pool <- function() model_state$pool

# Scalar literal for hand-built multi-row VALUES (NA -> NULL, timestamps and
# numerics quoted by DBI).
db_lit <- function(con, x) {
  if (length(x) != 1L) stop("db_lit expects a scalar")
  if (is.na(x)) return("NULL")
  as.character(DBI::dbQuoteLiteral(con, x))
}

# Vector version: `x[i]` keeps the class (a POSIXct column must not be
# iterated as a plain double or it would be quoted as epoch seconds).
db_lit_vec <- function(con, x) {
  vapply(seq_along(x), function(i) db_lit(con, x[i]), character(1),
         USE.NAMES = FALSE)
}

# ---- participants ----------------------------------------------------------

# One row per email (UNIQUE): Setup may send the same address on several
# days. marketing_consent only ever turns on (it is never revoked here).
# Returns list(id, created) or NULL.
db_participant_upsert <- function(email, marketing_consent, ip_hash, country) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  email <- if (is.null(email) || !is.character(email) || !nzchar(email)) {
    NULL
  } else {
    tolower(trimws(email))
  }
  db_try("participant_upsert", {
    if (!is.null(email)) {
      hit <- DBI::dbGetQuery(pool, paste0(
        "SELECT id FROM participants WHERE email = ",
        db_lit(pool, email)
      ))
      if (nrow(hit) == 1L) {
        if (isTRUE(marketing_consent)) {
          DBI::dbExecute(pool, paste0(
            "UPDATE participants SET marketing_consent = TRUE WHERE id = ",
            db_lit(pool, hit$id[[1]])
          ))
        }
        return(list(id = hit$id[[1]], created = FALSE))
      }
    }
    DBI::dbExecute(pool, paste(
      "INSERT INTO participants (email, marketing_consent, ip_hash, country)",
      "VALUES ($1, $2, $3, $4)"
    ), params = list(
      # RPostgres binds a length-0 parameter as an error, not as NULL: the
      # nullable columns of section 2.2 (optional email, CF country, missing
      # participant) travel as NA and become SQL NULL on the way in.
      email %||% NA_character_,
      isTRUE(marketing_consent),
      ip_hash,
      country %||% NA_character_
    ))
    row <- if (is.null(email)) {
      # No email: match on the hashed IP of this same request so repeat
      # players without an address do not spawn a participant per day.
      DBI::dbGetQuery(pool, paste0(
        "SELECT id FROM participants WHERE ip_hash = ",
        db_lit(pool, ip_hash), " ORDER BY created_at DESC LIMIT 1"
      ))
    } else {
      DBI::dbGetQuery(pool, paste0(
        "SELECT id FROM participants WHERE email = ", db_lit(pool, email)
      ))
    }
    if (nrow(row) != 1L) return(NULL)
    list(id = row$id[[1]], created = TRUE)
  })
}

# ---- experiments -----------------------------------------------------------

db_insert_experiment <- function(participant_id, resume_code_hash, share_token,
                                 seed, seed_is_custom, company,
                                 start_datetime, start_location_id,
                                 model_version, app_version,
                                 status = "in_progress") {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("insert_experiment", {
    rows <- DBI::dbGetQuery(pool, paste(
      "INSERT INTO experiments",
      "(participant_id, resume_code_hash, share_token, seed, seed_is_custom,",
      " status, company, start_datetime, start_location_id, model_version, app_version)",
      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
      "RETURNING id, created_at"
    ), params = list(
      participant_id %||% NA_character_,
      resume_code_hash,
      share_token,
      # BIGINT: bind as text so a whole-number double never turns into
      # "1e+15" on the way to Postgres.
      sprintf("%.0f", as.numeric(seed)),
      isTRUE(seed_is_custom),
      status,
      company,
      start_datetime,
      as.integer(start_location_id),
      model_version,
      app_version
    ))
    if (nrow(rows) != 1L) return(NULL)
    list(id = rows$id[[1]], created_at = rows$created_at[[1]])
  })
}

# setup -> in_progress once both model trajectories are stored. Guarded by the
# status so a background job that finishes after the player abandoned the day
# cannot resurrect it. Returns the row, "conflict" (no longer in setup) or NULL.
db_mark_trajectories_ready <- function(id) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("mark_trajectories_ready", {
    rows <- DBI::dbGetQuery(pool, paste0(
      "UPDATE experiments SET status = 'in_progress', updated_at = now()",
      " WHERE id = ", db_lit(pool, as.character(id)),
      " AND status = 'setup' RETURNING *"
    ))
    if (nrow(rows) == 1L) return(as.list(rows[1, , drop = FALSE]))
    "conflict"
  })
}

# Publishes the "setup" percentage on the row (plan C). Returns the number of
# rows updated: 0 is not an error, it means the day has already left setup and
# the writer is a stale child -- which is exactly what the status guard is for,
# so a child that outlives its parent can no longer overwrite a day that has
# moved on. Out-of-range values are clamped rather than left for the CHECK
# constraint to reject: a failed publish must not abort the trajectory.
db_publish_setup_progress <- function(id, progress) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  # A non-UUID is never an experiment (the writers' own tests pass a
  # placeholder), and letting Postgres reject it would log an error for a
  # call that is meant to be a no-op.
  if (!is_string(id) || !grepl(UUID_PATTERN, id)) return(NULL)
  progress <- max(0L, min(99L, as.integer(progress)))
  db_try("publish_setup_progress", {
    # dbExecute, not dbGetQuery: what matters is how many rows matched, and
    # that is what dbExecute returns without a RETURNING clause.
    as.integer(DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET setup_progress = ", progress,
      ", updated_at = now()",
      " WHERE id = ", db_lit(pool, as.character(id)),
      " AND status = 'setup'"
    )))
  })
}

# Bulk write of one trajectory (created in a single statement; ~50 rows).
# Returns the number of rows written, or NULL.
db_insert_decisions <- function(experiment_id, decision_source, decisions) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  if (is.null(decisions) || nrow(decisions) == 0L) return(0L)
  db_try("insert_decisions", {
    cols <- names(decisions)
    n <- nrow(decisions)
    exp_lit <- db_lit(pool, experiment_id)
    src_lit <- db_lit(pool, decision_source)
    col_lits <- lapply(decisions, function(col) db_lit_vec(pool, col))
    values <- vapply(seq_len(n), function(i) {
      paste0(
        "(", exp_lit, ", ", src_lit, ", ",
        paste(vapply(col_lits, `[[`, character(1), i), collapse = ", "), ")"
      )
    }, character(1))
    sql <- paste0(
      "INSERT INTO decisions (experiment_id, decision_source, ",
      paste(cols, collapse = ", "),
      ") VALUES ", paste(values, collapse = ", ")
    )
    as.integer(DBI::dbExecute(pool, sql))
  })
}

# Rows (0 or 1) or NULL on a database error, so callers can tell "no such
# experiment" (404) from "the database is down" (503).
# `lock` adds FOR SHARE (plan C): GET /state takes it so a concurrent flip of
# status cannot land between this read and the body built from it. What the
# statement really buys is that it waits for an in-flight UPDATE to finish;
# holding the lock past the response would need a transaction spanning the
# handler, and the body is built from this one snapshot anyway -- recorded in
# ADR-0009 rather than pretended away.
db_get_experiment <- function(id, lock = FALSE) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("get_experiment", DBI::dbGetQuery(pool, paste0(
    "SELECT * FROM experiments WHERE id = ", db_lit(pool, as.character(id)),
    if (lock) " FOR SHARE" else ""
  )))
}

db_get_experiment_by_token <- function(token) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("get_experiment_by_token", DBI::dbGetQuery(pool, paste0(
    "SELECT * FROM experiments WHERE share_token = ",
    db_lit(pool, as.character(token))
  )))
}

first_row <- function(rows) {
  if (is.null(rows) || nrow(rows) != 1L) return(NULL)
  as.list(rows[1, , drop = FALSE])
}

db_get_decisions <- function(experiment_id, decision_source) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  rows <- db_try("get_decisions", DBI::dbGetQuery(pool, paste0(
    "SELECT * FROM decisions WHERE experiment_id = ",
    db_lit(pool, as.character(experiment_id)),
    " AND decision_source = ", db_lit(pool, decision_source),
    " ORDER BY step"
  )))
  if (is.null(rows)) return(NULL)
  rows
}

# Natural-key insert: "inserted" on a new row, "duplicate" when the same
# payload is already stored (idempotent retry), "conflict" when the step was
# already decided differently (409), NULL on a database error.
db_insert_decision <- function(experiment_id, decision_source, step, trip_id,
                               accepted, model_recommended, trip_miles,
                               trip_time, driver_pay, tips, pu_location_id,
                               do_location_id, request_datetime,
                               dropoff_datetime) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("insert_decision", {
    rows <- DBI::dbGetQuery(pool, paste0(
      "INSERT INTO decisions (experiment_id, decision_source, step, trip_id,",
      " accepted, model_recommended, trip_miles, trip_time, driver_pay, tips,",
      " pu_location_id, do_location_id, request_datetime, dropoff_datetime)",
      " VALUES (", db_lit(pool, experiment_id), ", ",
      db_lit(pool, decision_source), ", ", db_lit(pool, as.integer(step)), ", ",
      db_lit(pool, as.numeric(trip_id)), ", ", db_lit(pool, accepted), ", ",
      db_lit(pool, model_recommended), ", ", db_lit(pool, trip_miles), ", ",
      db_lit(pool, as.integer(trip_time)), ", ", db_lit(pool, driver_pay), ", ",
      db_lit(pool, tips), ", ", db_lit(pool, as.integer(pu_location_id)), ", ",
      db_lit(pool, as.integer(do_location_id)), ", ",
      db_lit(pool, request_datetime), ", ", db_lit(pool, dropoff_datetime),
      ") ON CONFLICT (experiment_id, decision_source, step) DO NOTHING",
      " RETURNING step"
    ))
    if (nrow(rows) == 1L) return("inserted")
    existing <- DBI::dbGetQuery(pool, paste0(
      "SELECT trip_id, accepted FROM decisions WHERE experiment_id = ",
      db_lit(pool, as.character(experiment_id)),
      " AND decision_source = ", db_lit(pool, decision_source),
      " AND step = ", db_lit(pool, as.integer(step))
    ))
    if (nrow(existing) != 1L) return(NULL)
    same <- isTRUE(as.numeric(existing$trip_id[[1]]) == as.numeric(trip_id)) &&
      identical(as.logical(existing$accepted[[1]]), as.logical(accepted))
    if (same) "duplicate" else "conflict"
  })
}

# Flip to finished with the computed results. Returns the updated row as a
# list, "conflict" when the status is not in_progress, NULL on DB error.
db_finish_experiment <- function(id, final_user_wage, final_policy_wage,
                                 final_baseline_wage, pct_following_policy,
                                 outcome, user_percentile, trips_accepted,
                                 trips_rejected) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("finish_experiment", {
    rows <- DBI::dbGetQuery(pool, paste0(
      "UPDATE experiments SET final_user_wage = ", db_lit(pool, final_user_wage),
      ", final_policy_wage = ", db_lit(pool, final_policy_wage),
      ", final_baseline_wage = ", db_lit(pool, final_baseline_wage),
      ", pct_following_policy = ", db_lit(pool, pct_following_policy),
      ", outcome = ", db_lit(pool, outcome),
      ", user_percentile = ", db_lit(pool, user_percentile),
      ", status = 'finished', finished_at = now(), updated_at = now()",
      " WHERE id = ", db_lit(pool, as.character(id)),
      " AND status = 'in_progress' RETURNING *"
    ))
    if (nrow(rows) == 1L) return(as.list(rows[1, , drop = FALSE]))
    "conflict"
  })
}

db_update_feedback <- function(id, rating, comment, public) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("update_feedback", {
    # comment is optional in the contract: a missing one is SQL NULL, not a
    # missing literal. db_lit() rejects NULL outright ("expects a scalar"),
    # so submitting a rating without a comment used to fail the statement and
    # answer 503 "Database unavailable."
    if (is.null(comment)) comment <- NA_character_
    n <- DBI::dbExecute(pool, paste0(
      "UPDATE experiments SET feedback_rating = ", db_lit(pool, as.integer(rating)),
      ", feedback_comment = ", db_lit(pool, comment),
      ", feedback_public = ", db_lit(pool, isTRUE(public)),
      ", updated_at = now() WHERE id = ", db_lit(pool, as.character(id))
    ))
    n == 1L
  })
}

# Terminal state for a day the player never finished.
db_abandon_experiment <- function(id) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("abandon_experiment", {
    rows <- DBI::dbGetQuery(pool, paste0(
      "UPDATE experiments SET status = 'abandoned', updated_at = now()",
      " WHERE id = ", db_lit(pool, as.character(id)),
      " AND status IN ('setup', 'in_progress') RETURNING *"
    ))
    if (nrow(rows) == 1L) return(as.list(rows[1, , drop = FALSE]))
    "conflict"
  })
}

# Email a participant gave during Setup, for POST /experiments/{id}/share-email
# when the request body omits it. NULL when there is no participant or none.
db_participant_email <- function(participant_id) {
  if (is.null(participant_id) || length(participant_id) == 0L) return(NULL)
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  rows <- db_try("participant_email", DBI::dbGetQuery(pool, paste0(
    "SELECT email FROM participants WHERE id = ",
    db_lit(pool, as.character(participant_id[[1]]))
  )))
  if (is.null(rows) || nrow(rows) != 1L) return(NULL)
  email <- rows$email[[1]]
  if (is.null(email) || is.na(email) || !nzchar(email)) return(NULL)
  email
}

# ---- waitlist --------------------------------------------------------------

# TRUE when the address was stored, FALSE when it was already there.
db_insert_waitlist <- function(email, ip_hash) {
  pool <- db_pool()
  if (is.null(pool)) return(NULL)
  db_try("insert_waitlist", {
    n <- DBI::dbExecute(pool, paste0(
      "INSERT INTO waitlist (email, ip_hash) VALUES (",
      db_lit(pool, tolower(trimws(email))), ", ", db_lit(pool, ip_hash),
      ") ON CONFLICT (email) DO NOTHING"
    ))
    n == 1L
  })
}
