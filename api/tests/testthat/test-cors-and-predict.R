# CORS (section 5.7) and the two model functions, unit by unit.
#
# Neither had a single test before: `middleware_cors.R` and `ml_predict.R`
# both reported 0% coverage, which meant the origin rule that stops the API
# echoing `Origin: null`, and the "nothing is loaded yet" answers that every
# 503 depends on, were asserted nowhere.

test_that("cors_origin is one fixed origin per environment", {
  old <- Sys.getenv("ENV", unset = NA_character_)
  on.exit(if (is.na(old)) Sys.unsetenv("ENV") else Sys.setenv(ENV = old),
          add = TRUE)

  Sys.setenv(ENV = "production")
  expect_identical(cors_origin(), "https://nyctaxiapp.angelfeliz.com")

  Sys.setenv(ENV = "development")
  expect_identical(cors_origin(), "http://localhost:3838")

  # Unset behaves like every non-production value: the API is private, so a
  # mislabelled environment must fall back to the dev origin, never to "*".
  Sys.unsetenv("ENV")
  expect_identical(cors_origin(), "http://localhost:3838")
})

# The handler lives inside apply_cors(), so the test reaches it the way
# plumber2 does: build the api, install the routes, then take the handler back
# out of the route stack.
cors_handler <- function() {
  # port 1: the object is never bound, only built -- plumber2 still insists
  # the number is a legal port.
  api <- plumber2::api(host = "127.0.0.1", port = 1L)
  api <- apply_cors(api)
  route <- api$plugins$request_routr$get_route("cors_main")
  route$.__enclos_env__$private$handlerMap$all$`/*`$handler
}

# fake_response() only models set_header; this route also appends `Vary`.
cors_response <- function() {
  r <- fake_response()
  r$appended <- list()
  r$append_header <- function(name, value) {
    r$appended[[tolower(name)]] <- value
    invisible(NULL)
  }
  r
}

test_that("the CORS handler echoes only its own origin and always continues", {
  handler <- cors_handler()
  origin <- cors_origin()

  # Allowed: the request's origin is echoed back, so the browser accepts it.
  req <- list(get_header = function(n) {
    if (identical(tolower(n), "origin")) origin else NULL
  })
  resp <- cors_response()
  expect_true(handler(req, resp, NULL))
  expect_identical(resp$headers[["access-control-allow-origin"]], origin)
  expect_identical(resp$appended[["vary"]], "origin")

  # Case-insensitive on the way in, and the header carries back exactly what
  # the request sent -- what the browser asked for. Browsers always send a
  # canonical (lower-cased) origin, so in practice this is the configured
  # value unchanged; the tolerance is for non-browser clients.
  req <- list(get_header = function(n) {
    if (identical(tolower(n), "origin")) toupper(origin) else NULL
  })
  resp <- cors_response()
  expect_true(handler(req, resp, NULL))
  expect_identical(resp$headers[["access-control-allow-origin"]],
                   toupper(origin))

  # `Origin: null` and any foreign origin get the literal string
  # "false", which browsers refuse. They are never echoed.
  for (bad in list("null", "https://evil.example", origin, "")) {
    if (identical(bad, origin)) next
    req <- list(get_header = function(n) {
      if (identical(tolower(n), "origin")) bad else NULL
    })
    resp <- cors_response()
    expect_true(handler(req, resp, NULL))
    expect_identical(resp$headers[["access-control-allow-origin"]], "false")
  }

  # No Origin at all: server-to-server calls must keep going. Returning FALSE
  # here would stop routr's chain and every internal call would 404 -- which
  # is the bug the replacement handler in apply_cors() was written for.
  req <- list(get_header = function(n) NULL)
  resp <- cors_response()
  expect_true(handler(req, resp, NULL))
  expect_identical(resp$headers[["access-control-allow-origin"]], "false")
})

test_that("the model functions answer NULL when nothing is loaded", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)
  set_model_state()   # no policy, no tree

  # Not an error: POST /predict turns this into 503 and /validate-trip-start
  # into 503 as well, and the trajectory simulators break out of the day.
  expect_null(policy_probability(data.frame(x = 1)))
  expect_null(start_is_high_value(
    "Lyft", as.POSIXct("2025-01-05 16:00:00", tz = "UTC"), 61L
  ))

  # An empty frame is still not a crash: the null check runs first.
  expect_null(policy_probability(data.frame()))
})
