# Session state (master doc 6.3: `estado`). One reactiveValues per Shiny
# session -- never a global -- so `allow-container-re-use: true` in
# ShinyProxy cannot leak one visitor's day into the next one (6.1.5).

# `%||%` may not be loaded yet when this file is sourced by the tests.
`%||%` <- function(x, y) if (is.null(x)) y else x

# The client IP Nginx fixed in X-Client-IP (5.4). The app forwards it to the
# API on every call; the API only counts it together with a valid
# X-Internal-Key. ShinyProxy must pass the header through to the container --
# that is verified by the phase-4 test (and, end to end, in phase 7).
client_ip <- function(session) {
  req <- session$request
  if (is.null(req)) return("")
  ip <- req$HTTP_X_CLIENT_IP %||% req$HTTP_CF_CONNECTING_IP %||% req$REMOTE_ADDR
  if (is.null(ip) || !nzchar(trimws(ip))) "" else trimws(ip)
}

init_estado <- function(session) {
  reactiveValues(
    client_ip = client_ip(session),
    experiment_id = NULL,
    resume_code = NULL,
    share_token = NULL,
    state = NULL,         # latest DayState from the API
    status = NULL,        # setup | in_progress | finished | abandoned
    progress = 0L,        # model_progress while status is setup
    result = NULL,        # ExperimentResult once the day is finished
    experiment = NULL,    # last Experiment record (finish returns the full one)
    email = NULL          # given during Setup; the API never echoes it back
  )
}

# Snapshot of what the API client needs, built at call time so the resume code
# (shown once) and the IP are always the current ones.
estado_ctx <- function(estado) {
  shiny::isolate(api_ctx(
    ip = estado$client_ip %||% "",
    resume_code = estado$resume_code %||% ""
  ))
}

# POST /experiments answer: DayState plus the one-time credentials.
estado_set_created <- function(estado, created) {
  estado$experiment_id <- created$experiment_id
  estado$resume_code <- created$resume_code
  estado$share_token <- created$share_token
  estado_set_state(estado, created)
}

# Any DayState (create, /state poll, decision). The API omits model_progress
# as soon as the day leaves "setup", so the field is only copied when present.
# Reads go through isolate(): the callers are observers whose dependency is
# the API answer, not these fields, and isolating keeps them testable outside
# a reactive consumer.
estado_set_state <- function(estado, st) {
  if (is.null(st)) return(invisible(NULL))
  shiny::isolate({
    estado$state <- st
    if (!is.null(st$status)) estado$status <- st$status
    if (!is.null(st$experiment_id)) estado$experiment_id <- st$experiment_id
    if (!is.null(st$model_progress)) {
      estado$progress <- as.integer(st$model_progress)
    } else if (!identical(estado$status, "setup")) {
      estado$progress <- 100L
    }
    res <- st$result
    if (is.list(res) && length(res) > 0) estado$result <- res
  })
  invisible(st)
}

# The offer on the table: next_trip is null while the day is in setup and once
# it is over, and depending on how the JSON was parsed it arrives as NULL, NA
# or an empty object -- all three mean "no trip".
current_trip <- function(estado) {
  s <- estado$state
  if (is.null(s)) return(NULL)
  t <- s$next_trip
  if (!is.list(t) || length(t) == 0 || is.null(t$trip_id)) return(NULL)
  t
}

# The shift reached its 8h+30min limit (section 3). The UI then calls
# POST /finish, because outcome and user_percentile are computed there, on the
# server (4.6) -- never in the browser.
shift_over <- function(state) {
  if (is.null(state)) return(FALSE)
  h <- state$pending_hours
  if (is.null(h) || length(h) == 0) return(FALSE)
  h <- suppressWarnings(as.numeric(h[[1]]))
  isTRUE(length(h) == 1L && !is.na(h) && h <= 0)
}

# POST /finish answers an Experiment record (id, company, model_version, seed,
# seed_is_custom, result, feedback) -- NOT a DayState. So the history the
# Results curves need lives in estado$state and must survive this call
# untouched; only the record itself and the status are folded in here.
estado_set_finished <- function(estado, exp) {
  if (is.null(exp)) return(invisible(NULL))
  shiny::isolate({
    estado$experiment <- exp
    estado$status <- "finished"
    estado$progress <- 100L
    if (!is.null(exp$id)) estado$experiment_id <- as.character(exp$id)
    if (!is.null(exp$share_token)) {
      estado$share_token <- as.character(exp$share_token)
    }
    if (is.list(exp$result) && length(exp$result) > 0) {
      estado$result <- exp$result
    }
    s <- estado$state
    if (!is.null(s)) {
      s$status <- "finished"
      estado$state <- s
    }
  })
  invisible(exp)
}

# The day is ready to be played: create answered, trajectories computed.
estado_ready <- function(estado) {
  shiny::isolate(
    identical(estado$status, "in_progress") || identical(estado$status, "finished")
  )
}
