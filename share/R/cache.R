# Redis for the share service (sections 5.10 and 7.4): the share:views:{token}
# counters and the render tally behind /metrics. Nothing is ever written to
# disk. The rendered PNG bytes are deliberately NOT here any more (ADR-0010):
# the edge cache is the layer that keeps crawlers from re-rendering, and a
# second cache in front of it only hid renders from the only counter that
# reported them.
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

# ---- render tally (metrics, section 11) -----------------------------------

# One global counter, incremented once per card actually rendered. It replaces
# the two cache counters, which nothing ever incremented (ADR-0010) -- they
# read as zero forever while the cache in front of them hid the renders.
renders_incr <- function() {
  con <- redis_con()
  if (is.null(con)) return(NULL)
  tryCatch(as.integer(con$INCR("png:renders")), error = function(e) {
    redis_forget()
    NULL
  })
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
