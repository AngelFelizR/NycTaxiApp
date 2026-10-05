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

# INCR + TTL on first hit (rate limits, /metrics counters). NULL when Redis is
# unreachable: callers decide between fail-open (cache) and fail-closed (rate
# limit).
redis_incr <- function(key, ttl = 86400L) {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch({
    n <- as.integer(con$INCR(key))
    # ttl = NULL marks a lifetime counter (the /metrics business counters);
    # anything else expires with the daily window it belongs to.
    if (n == 1L && !is.null(ttl)) con$EXPIRE(key, as.integer(ttl))
    n
  }, error = function(e) {
    redis_forget()
    NULL
  })
}

# Counter read for /metrics: missing keys count as 0, Redis down as NULL.
redis_counters <- function(keys) {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch({
    vals <- con$MGET(keys)
    # The fallback has to be an integer literal: vapply's FUN.VALUE is
    # integer(1) and a missing key would otherwise come back as a double 0.
    out <- vapply(vals, function(v) {
      if (is.null(v)) 0L else as.integer(v)
    }, integer(1))
    stats::setNames(out, keys)
  }, error = function(e) {
    redis_forget()
    NULL
  })
}

# Sum of the values of every key matching a pattern (SCAN + MGET): the share
# views total for /metrics, which keeps one counter per token. NULL when Redis
# is down (the caller answers 500 rather than reporting fake zeros).
redis_pattern_sum <- function(pattern) {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch({
    keys <- character(0)
    cursor <- "0"
    repeat {
      res <- con$SCAN(cursor, MATCH = pattern, COUNT = 1000L)
      cursor <- as.character(res[[1]])
      keys <- c(keys, unlist(res[[2]], use.names = FALSE))
      if (identical(cursor, "0")) break
    }
    if (length(keys) == 0L) return(0)
    vals <- con$MGET(keys)
    sum(vapply(vals, function(v) if (is.null(v)) 0 else as.numeric(v), numeric(1)))
  }, error = function(e) {
    redis_forget()
    NULL
  })
}

# Counts a share card the first time its data is fetched: `share:gen:{token}`
# marks the token (no TTL) and `shares:generated` is the total /metrics reads.
# Best effort: a missing counter must not break the share page.
mark_share_generated <- function(token) {
  con <- redis_con()
  if (is.null(con)) return(invisible(NULL))
  tryCatch({
    key <- paste0("share:gen:", token)
    if (as.integer(con$EXISTS(key)) == 0L) {
      con$SET(key, "1")
      con$INCR("shares:generated")
    }
  }, error = function(e) redis_forget())
  invisible(NULL)
}
