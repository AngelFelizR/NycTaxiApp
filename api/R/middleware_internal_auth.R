# internal_auth middleware (section 5.4): every endpoint requires a valid
# X-Internal-Key; 403 without it. Runs in the header router, before the body
# is received, so invalid callers never reach the model code. The comparison
# is done on SHA-256 digests of both values instead of the raw strings.

secure_equal <- function(expected, provided) {
  identical(
    digest::digest(expected, algo = "sha256", serialize = FALSE),
    digest::digest(provided, algo = "sha256", serialize = FALSE)
  )
}

internal_auth_header <- function(request, response) {
  expected <- Sys.getenv("API_INTERNAL_KEY")
  provided <- request$get_header("x-internal-key")
  ok <- nzchar(expected) &&
    is.character(provided) && length(provided) == 1L && nzchar(provided) &&
    secure_equal(expected, provided)
  if (!ok) {
    return(api_error(
      response, 403L, "forbidden",
      "Invalid or missing X-Internal-Key header."
    ))
  }
  plumber2::Next
}
