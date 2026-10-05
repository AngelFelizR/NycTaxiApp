# Shared plumbing for the phase-3 experiment tests (test-experiments.R and
# test-experiments-async.R). Helpers live here because testthat sources them
# into one environment for every file, while definitions at the top of a test
# file are private to that file.

exp_ct <- list("content-type" = "application/json")

.test_seq <- new.env(parent = emptyenv())
test_seq <- function() {
  .test_seq$n <- (.test_seq$n %||% 0L) + 1L
  as.integer(.test_seq$n)
}

# Rate-limit address for the run: seconds since midnight * 1000 + a per-call
# counter (fits in three octets: 86_400_000 < 2^31). simulate_day() reseeds
# the RNG, so random draws would repeat across creates and collide with the
# daily buckets Redis still holds from an earlier run of this file; with this
# scheme two runs only collide if they start in the same second, and the key
# carries the calendar day anyway.
test_ip <- function() {
  v <- as.integer(as.numeric(Sys.time()) %% 86400) * 1000L + test_seq()
  sprintf("10.%d.%d.%d", (v %/% 65536L) %% 256L, (v %/% 256L) %% 256L, v %% 256L)
}
random_test_ip <- test_ip
test_email <- function(prefix) sprintf("%s%d@example.com", prefix, test_seq())

# Status of a handler that only writes the response: the handlers answer with
# `plumber2::Break`, which is not a list, so the response object is the only
# thing that carries status and body.
status_of <- function(handler, request, ...) {
  response <- fake_response()
  handler(request, response, ...)
  response
}

exp_headers <- function(ip = random_test_ip(), resume = NULL) {
  h <- c(exp_ct, list("x-client-ip" = ip))
  if (!is.null(resume)) h[["x-resume-code"]] <- resume
  h
}

# Drops what a test created (experiments cascade to their decisions).
drop_experiment <- function(id) {
  pool <- model_state$pool
  if (is.null(pool) || is.null(id)) return(invisible(FALSE))
  lit <- db_lit(pool, as.character(id))
  try(DBI::dbExecute(pool, paste0("DELETE FROM decisions WHERE experiment_id = ", lit)),
      silent = TRUE)
  try(DBI::dbExecute(pool, paste0("DELETE FROM experiments WHERE id = ", lit)),
      silent = TRUE)
  invisible(TRUE)
}

drop_waitlist <- function(email) {
  pool <- model_state$pool
  if (is.null(pool)) return(invisible(FALSE))
  try(DBI::dbExecute(pool, paste0(
    "DELETE FROM waitlist WHERE email = ", db_lit(pool, tolower(email))
  )), silent = TRUE)
  invisible(TRUE)
}

# Real Postgres and Redis from the root compose, the planted trip week and the
# deterministic policy of helper-sim.R. Every handler the block calls sees
# model_state exactly as a warmed-up API would.
with_api_db <- function(code) {
  skip_if_not(redis_available(), "Redis is not reachable")
  pool <- create_db_pool()
  if (is.null(pool)) skip("Postgres is not reachable")

  old <- list(
    pool = model_state$pool,
    schema = model_state$schema_ready,
    policy = model_state$policy_name,
    reference = model_state$reference
  )
  model_state$pool <- pool
  on.exit({
    model_state$pool <- old$pool
    model_state$schema_ready <- old$schema
    model_state$policy_name <- old$policy
    model_state$reference <- old$reference
  }, add = TRUE)

  if (!ensure_schema(pool)) skip("schema could not be applied")
  model_state$policy_name <- "fake"
  model_state$reference <- list(
    by_company = list(
      Lyft = seq(10, 40, length.out = 201),
      Uber = seq(10, 40, length.out = 201)
    )
  )
  plant_sim_data()
  on.exit(unplant_sim_data(), add = TRUE)
  with_accept_all_policy(force(code))
}

create_payload <- function(...) {
  payload <- list(
    company = "Lyft",
    start_datetime = "2024-05-12T08:00:00Z",
    start_location_id = 61,
    seed = 42
  )
  for (nm in names(list(...))) payload[[nm]] <- list(...)[[nm]]
  payload
}

create_exp <- function(payload = create_payload(), ip = random_test_ip()) {
  response <- fake_response()
  create_experiment_handler(fake_request(exp_headers(ip)), response,
                            json_raw(payload))
  response
}
