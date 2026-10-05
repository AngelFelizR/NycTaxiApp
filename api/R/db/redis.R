# Redis client for the sensitivity cache (phase 2). One lazy connection per
# process, shared by later phases (rate limits, metrics counters).
#
# Availability is best effort: if Redis is down, cache helpers return
# NULL/FALSE and /sensitivity computes fresh every time (fail open). The
# phase-3 rate limiter will fail closed instead, by contract (429/503).

redis_state <- new.env(parent = emptyenv())

redis_con <- function() {
  if (!is.null(redis_state$con)) return(redis_state$con)
  host <- Sys.getenv("REDIS_HOST", "redis")
  port <- as.integer(Sys.getenv("REDIS_PORT", "6379"))
  con <- tryCatch(redux::hiredis(host = host, port = port), error = function(e) NULL)
  if (is.null(con)) return(NULL)
  pong <- tryCatch(con$PING(), error = function(e) NULL)
  if (is.null(pong)) return(NULL)
  redis_state$con <- con
  con
}

redis_available <- function() !is.null(redis_con())

# Drop the cached connection after an error so the next call reconnects
# (e.g. Redis restarted while the API kept running).
redis_forget <- function() redis_state$con <- NULL

redis_get <- function(key) {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch(con$GET(key), error = function(e) {
    redis_forget()
    NULL
  })
}

redis_setex <- function(key, value, ttl) {
  con <- redis_con()
  if (is.null(con)) return(FALSE)
  tryCatch({
    con$SET(key, value)
    con$EXPIRE(key, as.integer(ttl))
    TRUE
  }, error = function(e) {
    redis_forget()
    FALSE
  })
}
