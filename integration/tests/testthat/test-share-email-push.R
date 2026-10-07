# ADR-005: the API pushes the card payload; share never calls back.
#
# The E2E script proves the behaviour end to end (it needs models and a
# database, so it does not run in CI). These are the static invariants, in the
# spirit of test-router-auth.R: cheap, and they fail the moment someone turns
# the cycle back on.

read_src <- function(rel) {
  paste(readLines(file.path(repo_root, rel), warn = FALSE), collapse = "\n")
}

test_that("share-email renders by pushing, never by pulling (ADR-005)", {
  src <- read_src("api/R/endpoint_share_email.R")

  # The push exists ...
  expect_match(src, "render_card_at_share(", fixed = TRUE,
               label = "the endpoint renders through share's internal route")
  # ... and it goes through the single payload builder, so /share-data and the
  # push cannot drift apart.
  expect_match(src, "share_data_payload(", fixed = TRUE,
               label = "the payload comes from the one builder")
  # ... and it never asks share to fetch from us: that is the cycle that made
  # POST /share-email time out after 10 s.
  expect_false(grepl("share_data_handler", src, fixed = TRUE),
               label = "share-email must not invoke the pulling handler")
})

test_that("the payload builder lives in exactly one place", {
  builders <- 0
  for (rel in c("api/R/endpoint_share_data.R",
                "api/R/endpoint_share_email.R")) {
    if (grepl("share_data_payload <- function", read_src(rel), fixed = TRUE)) {
      builders <- builders + 1
    }
  }
  expect_equal(builders, 1L,
               label = "share_data_payload defined once, used by both paths")
  expect_match(read_src("api/R/endpoint_share_data.R"),
               "response$body <- share_data_payload(", fixed = TRUE,
               label = "GET /share-data answers the same document")
})
