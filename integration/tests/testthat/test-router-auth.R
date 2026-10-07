# Section 10(d): "sin X-Internal-Key válida, cualquier endpoint de la API
# responde 403". The middleware itself is covered by api/tests/test-utils.R;
# what is not covered anywhere is that the router actually applies it to
# everything -- a catch-all that is removed, narrowed, or registered after the
# routes would leave the API open while every unit test still passes.
#
# api/plumber.R cannot be sourced (it starts the server), so this reads it.

test_that("api/plumber.R registers internal_auth_header as a catch-all", {
  txt <- paste(readLines(file.path(repo_root, "api", "plumber.R"),
                         warn = FALSE), collapse = "\n")

  hooks <- gregexpr('api_any_header\\s*\\(', txt, perl = TRUE)[[1]]
  # Exactly one: zero means no auth at all, more than one means someone
  # duplicated the registration and one of them is not on "/*".
  expect_equal(sum(hooks > 0), 1L,
               label = "number of api_any_header registrations")

  # The hook is request_context rather than internal_auth_header itself
  # (section 11): plumber2 allows a single header catch-all, so the per-request
  # log context rides along with auth. What matters for section 10(d) is that
  # the hook covers /* AND that it still performs the auth decision, which is
  # checked against the middleware's own source just below.
  expect_match(
    txt,
    'api_any_header\\(\\s*api\\s*,\\s*"\\/\\*"\\s*,\\s*request_context',
    perl = TRUE,
    label = "the hook covers /* and is request_context"
  )

  middleware <- paste(
    readLines(file.path(repo_root, "api", "R", "middleware",
                        "request_context.R"), warn = FALSE),
    collapse = "\n"
  )
  expect_match(
    middleware,
    "internal_auth_header\\(request, response\\)",
    perl = TRUE,
    label = "request_context performs the internal key check"
  )
})

test_that("the hook is registered before any route", {
  txt <- paste(readLines(file.path(repo_root, "api", "plumber.R"),
                         warn = FALSE), collapse = "\n")

  pos_hook  <- regexpr('api_any_header\\s*\\(', txt, perl = TRUE)
  pos_route <- regexpr('api_(?:get|post)\\s*\\(', txt, perl = TRUE)

  expect_true(pos_hook > 0, label = "api_any_header found")
  expect_true(pos_route > 0, label = "at least one route found")
  # plumber2 materialises the header router lazily and aborts if a route has
  # already done it (see the comment above the registration in api/plumber.R);
  # reordering would fail at startup, which is worse than failing here.
  expect_lt(as.integer(pos_hook), as.integer(pos_route))
})

test_that("share/ authenticates the same way", {
  # share/ is the other client of the private API and must be held to the
  # same rule, or a change there silently drops the key.
  txt <- paste(readLines(file.path(repo_root, "share", "R", "api_client.R"),
                         warn = FALSE), collapse = "\n")
  expect_match(txt, 'X-Internal-Key', fixed = TRUE)
})
