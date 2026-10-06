# Redis for the share service (sections 5.10 and 7.1): the rendered PNG bytes
# (24h TTL, so a spike of LinkedIn/X crawlers never re-renders the card) and
# the share:views:{token} counters. Nothing is ever written to disk.
#
# Availability is best effort: if Redis is down the card is rendered fresh and
# the view is simply not counted (fail open). The share page must not go down
# because a counter cannot be incremented.

cache_state <- new.env(parent = emptyenv())

redis_con <- function() {
  if (!is.null(cache_state$con)) return(cache_state$con)
  host <- Sys.getenv("REDIS_HOST", "127.0.0.1")
  port <- as.integer(Sys.getenv("REDIS_PORT", "6379"))
  con <- tryCatch(redux::hiredis(host = host, port = port), error = function(e) NULL)
  if (is.null(con)) return(NULL)
  pong <- tryCatch(con$PING(), error = function(e) NULL)
  if (is.null(pong)) return(NULL)
  cache_state$con <- con
  con
}

redis_forget <- function() cache_state$con <- NULL

# ---- PNG cache (7.1: bytes, TTL 24h, never on disk) -------------------------

# Redis hands bulk strings back as character; for the card that means the PNG
# bytes have to be re-materialised exactly as they were stored.
as_raw <- function(x) {
  if (is.raw(x)) return(x)
  if (is.character(x) && length(x) == 1L) return(charToRaw(x))
  NULL
}

png_cache_get <- function(token) {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch(as_raw(con$GET(paste0("share:png:", token))), error = function(e) {
    redis_forget()
    NULL
  })
}

png_cache_put <- function(token, bytes, ttl = 86400L) {
  con <- redis_con()
  if (is.null(con)) return(FALSE)
  tryCatch({
    con$SET(paste0("share:png:", token), bytes)
    con$EXPIRE(paste0("share:png:", token), as.integer(ttl))
    TRUE
  }, error = function(e) {
    redis_forget()
    FALSE
  })
}

png_cache_del <- function(token) {
  con <- redis_con()
  if (is.null(con)) return(FALSE)
  tryCatch({ con$DEL(paste0("share:png:", token)); TRUE },
           error = function(e) { redis_forget(); FALSE })
}

# ---- view counter (7.4) ----------------------------------------------------

# INCR and set the TTL on the first hit. Returns NULL when Redis is down so
# the caller can tell "not counted" from "counted once".
views_incr <- function(token) {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch({
    key <- paste0("share:views:", token)
    n <- as.integer(con$INCR(key))
    if (n == 1L) con$EXPIRE(key, 7776000L)   # 90 days, the week the card lives
    n
  }, error = function(e) {
    redis_forget()
    NULL
  })
}

views_get <- function(token) {
  con <- redis_con()
  if (is.null(con)) return(NA_integer_)
  tryCatch({
    v <- con$GET(paste0("share:views:", token))
    if (is.null(v)) NA_integer_ else as.integer(v)
  }, error = function(e) {
    redis_forget()
    NA_integer_
  })
}

views_del <- function(token) {
  con <- redis_con()
  if (is.null(con)) return(FALSE)
  tryCatch({ con$DEL(paste0("share:views:", token)); TRUE },
           error = function(e) { redis_forget(); FALSE })
}
