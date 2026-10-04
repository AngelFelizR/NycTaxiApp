test_that("has_hint accepts only a single non-empty string", {
  expect_true(has_hint("Use Uber for better results"))
  expect_false(has_hint(""))
  expect_false(has_hint(NULL))
  expect_false(has_hint(c("a", "b")))
  expect_false(has_hint(1))
})

test_that("zone_or_null maps the '-' placeholder and NULL to NULL", {
  expect_null(zone_or_null("-"))
  expect_null(zone_or_null(NULL))
  expect_equal(zone_or_null("Queens - Jamaica"), "Queens - Jamaica")
})

test_that("line_plot builds a ggplot from the API history", {
  history <- data.frame(step = 0:3, user = c(0, 10, 25, 30), policy = c(0, 12, 20, 33))
  expect_s3_class(line_plot(history, "user"), "ggplot")
  expect_s3_class(line_plot(history, "policy"), "ggplot")
})

test_that("basemap returns a leaflet widget", {
  skip_if_not_installed("leaflet")
  expect_s3_class(basemap(), "leaflet")
})
