# Per-IP daily rate limits (section 5.4): 3 experiments/day and 5 waitlist
# signups/day, keyed in Redis by `sha256(IP_HASH_SALT || ip)` + UTC day, with
# a sliding expiry at midnight UTC.
#
# Fail-closed (the note in db/redis.R): when Redis is down the counter cannot
# be enforced, so the request is rejected with 503 instead of being let
# through. Rate-limit headers are set on the way out (logged, never shown in
# the UI).

# Counter names are stable so /metrics and the smoke script can read them.
rate_limit_key <- function(kind, ip_hash) {
  sprintf("%s:ip:%s:%s", kind, ip_hash, format(Sys.Date(), "%Y%m%d"))
}

seconds_until_midnight_utc <- function() {
  now <- as.POSIXct(Sys.time(), tz = "UTC")
  midnight <- as.POSIXct(format(now + 86400, "%Y-%m-%d 00:00:00"), tz = "UTC")
  as.integer(max(0, as.numeric(difftime(midnight, now, units = "secs"))))
}

set_rate_limit_headers <- function(response, limit, remaining, reset) {
  # reqres::Response exposes set_header() (snake_case); setHeader() does not
  # exist and calling it throws, which plumber2 turns into a bare 500.
  response$set_header("X-RateLimit-Limit", as.character(as.integer(limit)))
  response$set_header("X-RateLimit-Remaining", as.character(as.integer(max(0, remaining))))
  response$set_header("X-RateLimit-Reset", as.character(as.integer(reset)))
  invisible(NULL)
}

# Returns NULL when the caller is under the limit, plumber2::Break otherwise
# (429 with Retry-After + X-RateLimit-*, or 503 when Redis is unavailable).
rate_limit_check <- function(request, response, kind, limit, message) {
  ip_hash <- client_ip_hash(request)
  key <- rate_limit_key(kind, ip_hash)
  n <- redis_incr(key, ttl = 86400L)
  reset <- seconds_until_midnight_utc()
  if (is.null(n)) {
    return(api_error(
      response, 503L, "service_unavailable",
      "Rate limit service unavailable."
    ))
  }
  # The counter has already been incremented, so the request that crosses the
  # limit would report a negative remainder: the header never goes below zero.
  set_rate_limit_headers(response, limit, max(0L, limit - n), reset)
  if (n > limit) {
    response$set_header("Retry-After", as.character(reset))
    return(api_error(response, 429L, "rate_limit_exceeded", message))
  }
  NULL
}
