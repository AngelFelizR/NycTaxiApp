# Real client IP resolution (section 5.4). The API never sees browser traffic:
# `app/` and `share/` forward the IP that Nginx took from `CF-Connecting-IP`
# in the `X-Client-IP` header, next to `X-Internal-Key` (already validated by
# internal_auth_header). Only the SHA-256 of `IP_HASH_SALT || ip` is ever
# stored or used as a rate-limit key, so neither Redis nor Postgres nor the
# logs hold a clear IP.
#
# A missing/blank header degrades to the literal bucket "unknown": the doc's
# reference implementation does exactly that (`req$HTTP_X_CLIENT_IP %||%
# "unknown"`), so a client that forgets the header shares one counter instead
# of bypassing the limit.

client_ip_value <- function(request) {
  ip <- request$get_header("x-client-ip")
  if (is.null(ip) || !is.character(ip) || length(ip) != 1L || is.na(ip)) {
    return("unknown")
  }
  ip <- trimws(ip)
  if (!nzchar(ip)) "unknown" else ip
}

client_ip_hash <- function(request) {
  digest::digest(
    paste0(Sys.getenv("IP_HASH_SALT"), client_ip_value(request)),
    algo = "sha256",
    serialize = FALSE
  )
}

# Two-letter Cloudflare country, or NULL. Stored on the participant (never an
# IP) and never used for rate limiting: the limit key is the real IP, so
# CF-IPCountry only attenuates it when present.
client_country <- function(request) {
  cc <- request$get_header("cf-ipcountry")
  if (is.null(cc) || !is.character(cc) || length(cc) != 1L || is.na(cc)) {
    return(NULL)
  }
  cc <- trimws(toupper(cc))
  if (grepl("^[A-Z]{2}$", cc)) cc else NULL
}
