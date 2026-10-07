# Session isolation (6.1.5): ShinyProxy runs with `allow-container-re-use:
# true`, so the container a visitor lands in may have served somebody else a
# minute ago. Everything a visitor owns therefore has to be created when the
# session is, which means nothing session-shaped can live in a file scope.
#
# Two complementary checks: the static one is what actually prevents the bug
# (a `<<-` or an env in a module would leak across visitors), the dynamic one
# proves init_estado() hands out independent objects.

app_source_files <- function() {
  # R/ is flat since ADR-0007: the modules live here too, so one directory is
  # the whole surface. _disable_autoload.R is comments only, harmless to scan.
  list.files(file.path(app_dir, "R"), pattern = "\\.[rR]$", full.names = TRUE)
}

# Comments are stripped so a note explaining why there is no `<<-` does not
# trip the assertion that says there is none.
code_lines <- function(f) sub("#.*$", "", readLines(f, warn = FALSE))

test_that("no file in app/ mutates an enclosing scope", {
  for (f in app_source_files()) {
    code <- code_lines(f)
    expect_false(any(grepl("<<-", code, fixed = TRUE)),
                 label = paste(basename(f), "uses no super-assignment"))
    expect_false(any(grepl("assign(", code, fixed = TRUE)),
                 label = paste(basename(f), "uses no assign()"))
  }
})

test_that("the only environment in app/ is the preloaded-data cache", {
  owners <- unlist(lapply(app_source_files(), function(f) {
    if (any(grepl("new.env(", code_lines(f), fixed = TRUE))) basename(f)
  }))
  # constants.R caches companies/zones/options preloaded at startup (6.1.3):
  # shared data, never a visitor's. A second environment anywhere else would
  # be state that outlives the session that created it.
  expect_setequal(owners, "constants.R")
})

test_that("two sessions get their own estado and never see each other", {
  a <- init_estado(fake_session(list(HTTP_X_CLIENT_IP = "203.0.113.9")))
  b <- init_estado(fake_session(list(HTTP_X_CLIENT_IP = "198.51.100.7")))

  # Not the same object, and writing to one leaves the other alone.
  expect_false(identical(a, b))
  a$experiment_id <- "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
  a$resume_code <- "s3cr3t-resume"
  a$email <- "visitor-a@example.com"
  a$share_token <- "aZ3kQ9mLp1Rt"

  isolate({
    expect_null(b$experiment_id)
    expect_null(b$resume_code)
    expect_null(b$email)
    expect_null(b$share_token)
    # Each keeps the address it was created with.
    expect_equal(a$client_ip, "203.0.113.9")
    expect_equal(b$client_ip, "198.51.100.7")
  })

  # And a third one starts clean even after both have been written to.
  c_session <- init_estado(fake_session())
  isolate(expect_null(c_session$experiment_id))
})
