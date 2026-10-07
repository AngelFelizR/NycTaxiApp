# Section 10: "Ninguna respuesta pública (/share/*, PNG) contiene el
# `experiment_id` ni emails." Two angles, because neither one alone is enough:
# the contract says what a client may read, and the renderer decides what
# actually reaches the page.

contract_file <- file.path(share_dir, "..", "contract", "openapi.yaml")

test_that("the ShareDataResponse schema declares no identifier or address", {
  doc <- yaml::read_yaml(contract_file)
  props <- names(doc$components$schemas$ShareDataResponse$properties)
  expect_gt(length(props), 5)

  # Anything that points back at a person or a run must not be readable from
  # the public card (5.7, 9.1).
  for (forbidden in c("experiment_id", "email", "name", "resume_code",
                      "ip_hash", "participant_id")) {
    expect_false(forbidden %in% props,
                 label = paste("ShareDataResponse must not expose", forbidden))
  }
  # The identity the card does show is derived from the public share token.
  expect_true("day_label" %in% props)
})

test_that("the renderer picks its fields instead of dumping the payload", {
  # Hand it a payload that already carries the two things the contract forbids.
  # If share_page() ever interpolates the whole object, these show up in the
  # document -- and in every crawler that fetches the Open Graph tags.
  payload <- c(
    share_fixture(),
    list(
      experiment_id = "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
      email = "visitor@example.com",
      resume_code = "Gh7Kq2mZx9LpW4vRt8Yb1c",
      ip_hash = "e3b0c44298fc1c149afbf4c8996fb924"
    )
  )

  html <- share_page(payload, "aZ3kQ9mLp1Rt")
  expect_false(grepl("3f2504e0", html, fixed = TRUE),
               label = "experiment_id must not reach the page")
  expect_false(grepl("visitor@example.com", html, fixed = TRUE),
               label = "an email must not reach the page")
  expect_false(grepl("Gh7Kq2mZx9LpW4vRt8Yb1c", html, fixed = TRUE),
               label = "resume_code must not reach the page")
  expect_false(grepl("e3b0c44298fc1c149afbf4c8996fb924", html, fixed = TRUE),
               label = "ip_hash must not reach the page")

  # ...while the whitelisted identity does: the page still works.
  expect_match(html, "Day #aZ3kQ9", fixed = TRUE)
  expect_match(html, "I beat the Model!", fixed = TRUE)

  # The card goes through the same object; a payload that poisons the page
  # would poison the PNG too, so it has to render.
  expect_identical(as.integer(share_png(payload)[1:4]), c(137L, 80L, 78L, 71L))
})
