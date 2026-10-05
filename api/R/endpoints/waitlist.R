# POST /waitlist (sections 5.3, 5.7): called by the public share service when
# the app is at capacity. Validates the address and stores email + hashed IP;
# the contract's country column does not exist (section 2.2 is the schema
# source of truth), so CF-IPCountry is deliberately not persisted here.

waitlist_handler <- function(request, response, body) {
  if (is.null(db_pool()) || !schema_ready()) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }

  limited <- rate_limit_check(
    request, response, "waitlist", 5L,
    "You've reached the limit of 5 signups per day."
  )
  if (!is.null(limited)) return(limited)

  payload <- read_json_body(body, request)
  if (is_api_fail(payload)) {
    return(api_error(response, payload$status, payload$error, payload$message))
  }
  if (length(missing_fields(payload, c("email"))) > 0) {
    return(api_error(response, 400L, "bad_request", "Missing required field(s): email."))
  }
  if (!is_string(payload$email)) {
    return(api_error(response, 400L, "bad_request", "email must be a string."))
  }
  email <- trimws(payload$email)
  if (!is_email(email)) {
    return(api_error(
      response, 422L, "unprocessable_entity", "That email address is not valid."
    ))
  }

  stored <- db_insert_waitlist(email, client_ip_hash(request))
  if (is.null(stored)) {
    return(api_error(response, 503L, "service_unavailable", "Database unavailable."))
  }
  if (stored) redis_incr("waitlist:signups")

  response$body <- list(
    message = "You are on the waitlist. We will email you when a spot opens."
  )
  plumber2::Break
}
