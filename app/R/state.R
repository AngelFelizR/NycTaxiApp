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
    result = NULL         # ExperimentResult once the day is finished
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

# The day is ready to be played: create answered, trajectories computed.
estado_ready <- function(estado) {
  shiny::isolate(
    identical(estado$status, "in_progress") || identical(estado$status, "finished")
  )
}
