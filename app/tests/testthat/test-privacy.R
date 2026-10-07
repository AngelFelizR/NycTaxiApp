# Section 9.1 makes the privacy notice mandatory before publishing, and
# mod_setup already links to it -- so a missing or hollow page is a 404 in
# production, not a cosmetic problem.

privacy_path <- function() file.path(app_dir, "www", "privacy.html")

test_that("app/www/privacy.html exists and is a static page", {
  expect_true(file.exists(privacy_path()))
  html <- paste(readLines(privacy_path(), warn = FALSE), collapse = "\n")
  # LinkedIn-style crawlers are irrelevant here, but a notice served with no
  # JavaScript has to work with scripts blocked, like the share page (7.2).
  expect_false(grepl("<script", html, fixed = TRUE))
  expect_match(html, "<!doctype html>")
  expect_match(html, 'name="viewport"')
  expect_match(html, "Privacy notice")
})

test_that("the notice covers every item 9.1 requires", {
  html <- paste(readLines(privacy_path(), warn = FALSE), collapse = "\n")
  # what is stored
  expect_match(html, "email", ignore.case = TRUE)
  expect_match(html, "name", ignore.case = TRUE)
  expect_match(html, "decisions in the simulation")
  expect_match(html, "hash of your IP")
  expect_false(grepl("plain IP address is never", html) &&
                 !grepl("never", html),
               label = "the notice must state the IP is not stored in clear")
  # why
  expect_match(html, "resume", ignore.case = TRUE)
  expect_match(html, "result card", ignore.case = TRUE)
  expect_match(html, "consent", ignore.case = TRUE)
  # localStorage vs cookies (9.1 is specific about this)
  expect_match(html, "localStorage")
  expect_match(html, "no tracking cookies", ignore.case = TRUE)
  # retention
  expect_match(html, "indefinitely")
  expect_match(html, "28 days")
  # how to ask for erasure
  expect_match(html, "Data deletion request")
  expect_match(html, "mailto:")
})

test_that("Setup and the footer both link to it", {
  setup <- paste(readLines(file.path(app_dir, "R", "modules", "mod_setup.R"),
                           warn = FALSE), collapse = "\n")
  expect_match(setup, 'href = "privacy.html"', fixed = TRUE)

  app_r <- paste(readLines(file.path(app_dir, "app.R"), warn = FALSE),
                 collapse = "\n")
  # 9.1 asks for the link in the footer; page_navbar's `footer` is the only
  # place that renders on every panel.
  expect_match(app_r, "footer = div(", fixed = TRUE)
  expect_match(app_r, 'href = "privacy.html"', fixed = TRUE)
})
