# GET /metrics (section 6.8): ad-hoc business counters as plain JSON, straight
# from Redis. No Prometheus/Grafana by decision -- the numbers are for the
# operator and the smoke script, so a Redis outage is a 500 rather than a page
# of plausible-looking zeros.

metrics_handler <- function(request, response) {
  counters <- redis_counters(c(
    "exp:started", "exp:finished", "exp:abandoned", "shares:generated",
    "sens:cache:hits", "sens:cache:misses",
    # ADR-0010: the PNG cache is gone and so are its two counters -- which
    # nothing ever incremented, so they read zero while the cache in front of
    # them hid the renders. One tally for the work actually done.
    "png:renders",
    "waitlist:signups", "capacity:503"
  ))
  if (is.null(counters)) {
    return(api_error(response, 500L, "internal_error", "Metrics are unavailable."))
  }
  # Views live one counter per share token (share service INCRs on every HTML
  # view), so the total is the sum of the pattern.
  views <- redis_pattern_sum("share:views:*")
  if (is.null(views)) {
    return(api_error(response, 500L, "internal_error", "Metrics are unavailable."))
  }
  take <- function(key) as.integer(counters[[key]] %||% 0L)
  response$body <- list(
    experiments_started = take("exp:started"),
    experiments_finished = take("exp:finished"),
    experiments_abandoned = take("exp:abandoned"),
    shares_generated = take("shares:generated"),
    share_views_total = as.integer(views),
    sensitivity_cache_hits = take("sens:cache:hits"),
    sensitivity_cache_misses = take("sens:cache:misses"),
    png_renders_total = take("png:renders"),
    waitlist_signups = take("waitlist:signups"),
    capacity_503_total = take("capacity:503")
  )
  plumber2::Break
}
