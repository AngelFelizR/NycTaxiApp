# POST /experiments/{id}/share-email (sections 5.6, 5.2): synchronous SMTP
# send, no queues and no retries. The PNG comes from the share service over
# the private network; if share or SMTP is down the answer is 503 and the user
# decides whether to try again. Limits: 3 sends per experiment plus the
# per-IP daily limit, so the endpoint cannot be used as a spam relay.
#
# curl (the CLI, section 5.6) does the actual delivery: it speaks SMTP with
# --mail-from/--mail-rcpt/--upload-file, and the credentials stay out of argv
# by living in a 0600 temp config file instead of on the command line.

share_email_from <- function() {
  Sys.getenv("SMTP_FROM", "no-reply@angelfeliz.com")
}

share_base_url <- function() {
  sub("/+$", "", Sys.getenv("SHARE_URL", "http://share:8001"))
}

# The result card PNG, or NULL when share is unreachable/failed (503).
fetch_share_png <- function(token) {
  url <- paste0(share_base_url(), "/share/", token, ".png")
  dest <- tempfile(fileext = ".png")
  on.exit(unlink(dest), add = TRUE)
  status <- tryCatch(
    utils::download.file(url, destfile = dest, quiet = TRUE, mode = "wb",
                         method = "libcurl"),
    error = function(e) 1L,
    warning = function(w) 1L
  )
  if (!identical(as.integer(status), 0L) || !file.exists(dest)) return(NULL)
  size <- file.size(dest)
  if (is.na(size) || size < 1000) return(NULL)
  readBin(dest, what = "raw", n = size)
}

# Port of an SMTP URL, tolerating credentials (smtp://user:pass@host:587).
smtp_port <- function(smtp_url) {
  hostpart <- sub("^[a-zA-Z]+://", "", smtp_url)
  hostpart <- sub("^[^@]*@", "", hostpart)
  hostpart <- sub("[/?#].*$", "", hostpart)
  if (!grepl(":", hostpart, fixed = TRUE)) return("")
  sub("^.*:", "", hostpart)
}

# STARTTLS for plain smtp:// on the submission port (587), unless SMTP_URL is
# already smtps:// (implicit TLS) or SMTP_STARTTLS says otherwise.
smtp_requires_starttls <- function(smtp_url) {
  if (startsWith(smtp_url, "smtps://")) return(FALSE)
  if (isTRUE(as.logical(Sys.getenv("SMTP_STARTTLS", "")))) return(TRUE)
  identical(smtp_port(smtp_url), "587")
}

base64_wrapped <- function(bytes) {
  strwrap(jsonlite::base64_enc(bytes), width = 76)
}

# RFC 5322 message with one text part and the PNG as a base64 attachment.
build_share_email_mime <- function(to, from, subject, text, png_bytes,
                                   filename = "nyctaxi-day.png") {
  boundary <- paste0("----=_NextPart_", digest::digest(runif(1), algo = "md5"))
  body <- c(
    paste0("From: ", from),
    paste0("To: ", to),
    paste0("Subject: ", subject),
    "MIME-Version: 1.0",
    paste0("Content-Type: multipart/mixed; boundary=\"", boundary, "\""),
    "",
    paste0("--", boundary),
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    text,
    paste0("--", boundary),
    paste0("Content-Type: image/png; name=\"", filename, "\""),
    "Content-Transfer-Encoding: base64",
    paste0("Content-Disposition: attachment; filename=\"", filename, "\""),
    "",
    base64_wrapped(png_bytes),
    paste0("--", boundary, "--"),
    ""
  )
  charToRaw(paste(body, collapse = "\r\n"))
}

# Delivers the message through SMTP_URL. FALSE (never throws) on any failure.
send_via_smtp <- function(smtp_url, from, to, message) {
  cfg <- tempfile(fileext = ".curlcfg")
  eml <- tempfile(fileext = ".eml")
  on.exit(unlink(c(cfg, eml)), add = TRUE)
  writeLines(paste0("url = \"", smtp_url, "\""), cfg)
  Sys.chmod(cfg, "600")
  writeBin(message, eml)
  Sys.chmod(eml, "600")

  args <- c(
    "--config", cfg,
    "--mail-from", from,
    "--mail-rcpt", to,
    "--upload-file", eml,
    "--silent", "--show-error",
    "--max-time", "30"
  )
  if (smtp_requires_starttls(smtp_url)) args <- c(args, "--ssl-reqd")

  out <- suppressWarnings(
    system2("curl", args = args, stdout = TRUE, stderr = TRUE)
  )
  status <- attr(out, "status")
  if (is.null(status)) return(TRUE)
  cat("smtp curl exit ", status, ": ", paste(out, collapse = " "), "\n",
      file = stderr())
  FALSE
}

share_email_handler <- function(request, response, id, body) {
  auth <- auth_experiment(request, response, id)
  if (!auth$ok) return(auth$fail)
  exp <- auth$experiment

  limited <- rate_limit_check(
    request, response, "mail", 10L,
    "Rate limit exceeded, please try again later."
  )
  if (!is.null(limited)) return(limited)

  payload <- if (is.null(body) || length(body) == 0L) {
    list()
  } else {
    parsed <- read_json_body(body, request)
    if (is_api_fail(parsed)) {
      return(api_error(response, parsed$status, parsed$error, parsed$message))
    }
    parsed
  }
  if (!is.null(payload$email) && !is_string(payload$email)) {
    return(api_error(response, 400L, "bad_request", "email must be a string."))
  }

  email <- payload$email %||% db_participant_email(exp$participant_id)
  if (is.null(email)) {
    return(api_error(
      response, 422L, "unprocessable_entity",
      "email is required when it was not provided during Setup."
    ))
  }
  email <- trimws(email)
  if (!is_email(email)) {
    return(api_error(
      response, 422L, "unprocessable_entity", "That email address is not valid."
    ))
  }
  if (!identical(as.character(exp$status), "finished")) {
    return(api_error(
      response, 422L, "unprocessable_entity",
      "The experiment has not finished yet."
    ))
  }

  smtp_url <- trimws(Sys.getenv("SMTP_URL"))
  if (!nzchar(smtp_url)) {
    return(api_error(
      response, 503L, "service_unavailable",
      "We couldn't send the email, please try again later."
    ))
  }

  sends <- redis_incr(paste0("exp:email:", exp$id), ttl = 86400L)
  if (is.null(sends)) {
    return(api_error(
      response, 503L, "service_unavailable", "Rate limit service unavailable."
    ))
  }
  if (sends > 3L) {
    response$set_header("Retry-After", as.character(seconds_until_midnight_utc()))
    return(api_error(
      response, 429L, "rate_limit_exceeded",
      "You've reached the limit of 3 emails for this experiment."
    ))
  }

  png <- fetch_share_png(as.character(exp$share_token))
  if (is.null(png)) {
    cat("share-email: PNG fetch failed for ", exp$id, "\n", file = stderr())
    return(api_error(
      response, 503L, "service_unavailable",
      "We couldn't send the email, please try again later."
    ))
  }

  day_label <- paste0("Day #", substr(as.character(exp$share_token), 1, 6))
  outcome <- as.character(exp$outcome)
  message <- build_share_email_mime(
    to = email,
    from = share_email_from(),
    subject = paste0("Your NYC taxi result card (", day_label, ")"),
    text = paste(
      outcome_context_line(outcome, isTRUE(exp$seed_is_custom)),
      "",
      outcome_share_text(outcome, isTRUE(exp$seed_is_custom)),
      "",
      "Open your card: ", share_base_url(), "/share/", exp$share_token,
      sep = "\n"
    ),
    png_bytes = png
  )

  if (!send_via_smtp(smtp_url, share_email_from(), email, message)) {
    return(api_error(
      response, 503L, "service_unavailable",
      "We couldn't send the email, please try again later."
    ))
  }

  response$body <- list(message = "Email sent.")
  plumber2::Break
}
