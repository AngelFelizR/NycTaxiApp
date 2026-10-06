# shared/*.yaml: one visual spec for app/ and share/ (docs/decisions/0003).
# YAML has no schema, so these are what turn a typo into a red test instead of
# an NA in the middle of a chart.

test_that("shared_dir() resolves the shared/ directory from the test cwd", {
  expect_true(dir.exists(shared_dir()))
  expect_true(file.exists(file.path(shared_dir(), "curves.yaml")))
  expect_true(file.exists(file.path(shared_dir(), "brand.yaml")))
})

test_that("the curve spec is exactly three series, in legend order", {
  s <- curve_specs()
  expect_s3_class(s, "data.frame")
  expect_equal(nrow(s), 3L)
  expect_equal(s$name, c("user", "policy", "baseline"))
  expect_true(all(nzchar(s$label)))
  expect_false(anyDuplicated(s$label) > 0)
  expect_true(all(grepl("^#[0-9a-fA-F]{6}$", s$colour)))
  expect_false(anyDuplicated(s$colour) > 0)
})

test_that("the accessors are named the way their consumers expect", {
  expect_equal(unname(curve_labels()), c("You", "Model", "Accept all"))
  expect_equal(names(curve_labels()), c("user", "policy", "baseline"))
  # Named by LABEL: that is the lookup key of ggplot2::scale_colour_manual.
  expect_equal(names(curve_colours()), unname(curve_labels()))
  expect_true(all(grepl("^#", unname(curve_colours()))))
})

test_that("the brand palette holds the two documented variants", {
  expect_true(grepl("^#[0-9a-fA-F]{6}$", brand_colour("primary")))
  expect_true(grepl("^#[0-9a-fA-F]{6}$", brand_colour("primary_dark")))
  expect_false(identical(brand_colour("primary"), brand_colour("primary_dark")))
  expect_error(brand_colour("nope"), "unknown variant")
  # Same call the default path uses.
  expect_equal(brand_colour(), brand_colour("primary"))
})

test_that("the player's curve is the brand colour -- if that stops being true, say so here", {
  expect_equal(unname(curve_colours()[["You"]]), brand_colour("primary"))
})

test_that("strings.R re-exports the shared labels instead of its own copies", {
  expect_identical(label_curve_user, curve_labels()[["user"]])
  expect_identical(label_curve_policy, curve_labels()[["policy"]])
  expect_identical(label_curve_baseline, curve_labels()[["baseline"]])
})

# ---- the validators, fed garbage -------------------------------------------

test_that("validate_curves rejects structurally wrong documents", {
  expect_error(validate_curves(list()), "expected a `series:` list")
  expect_error(validate_curves(list(series = 1)), "expected a `series:` list")
  expect_error(validate_curves(list(series = list())),
               "expected exactly 3 series, got 0")
  expect_error(validate_curves(list(series = list("You"))), "must be a mapping")
  expect_error(
    validate_curves(list(series = list(
      list(name = "player"), list(name = "model"), list(name = "all")))),
    "must be user, policy, baseline in that order")
  expect_error(
    validate_curves(list(series = list(
      list(name = "user", label = "You", colour = "#6d5dfc"),
      list(name = "policy", label = "", colour = "#0369a1"),
      list(name = "baseline", label = "Accept all", colour = "#94a3b8")))),
    "`label` must be a non-empty string")
  # Present names and labels, but no colour at all.
  expect_error(
    validate_curves(list(series = list(
      list(name = "user", label = "You", colour = "#6d5dfc"),
      list(name = "policy", label = "Model", colour = "#0369a1"),
      list(name = "baseline", label = "Accept all")))),
    "`colour` must be a quoted 6-digit hex")
})

test_that("validate_curves catches the unquoted-# mistake", {
  # `colour: #6d5dfc` (no quotes) parses as null -- the whole point of the
  # validator, because YAML would otherwise hand an NA to ggplot2.
  expect_error(
    validate_curves(list(series = list(
      list(name = "user", label = "You", colour = NULL),
      list(name = "policy", label = "Model", colour = "#0369a1"),
      list(name = "baseline", label = "Accept all", colour = "#94a3b8")))),
    "A bare # starts a YAML comment")
})

test_that("validate_curves rejects duplicated labels and colours", {
  expect_error(
    validate_curves(list(series = list(
      list(name = "user", label = "You", colour = "#6d5dfc"),
      list(name = "policy", label = "You", colour = "#0369a1"),
      list(name = "baseline", label = "Accept all", colour = "#94a3b8")))),
    "`label` values must be unique")
  expect_error(
    validate_curves(list(series = list(
      list(name = "user", label = "You", colour = "#6d5dfc"),
      list(name = "policy", label = "Model", colour = "#6d5dfc"),
      list(name = "baseline", label = "Accept all", colour = "#94a3b8")))),
    "`colour` values must be unique")
})

test_that("validate_brand rejects missing, malformed and identical entries", {
  expect_error(validate_brand("nope"), "expected a mapping")
  expect_error(validate_brand(list()), "missing `primary` and `primary_dark`")
  expect_error(validate_brand(list(primary = "#6d5dfc")),
               "missing `primary_dark`")
  expect_error(validate_brand(list(primary = "#6d5dfc", primary_dark = "purple")),
               "must be a quoted 6-digit hex")
  expect_error(validate_brand(list(primary = "#6d5dfc", primary_dark = "#6d5dfc")),
               "must be different")
  expect_equal(validate_brand(list(primary = "#111111", primary_dark = "#222222")),
               list(primary = "#111111", primary_dark = "#222222"))
})

test_that("the cache is read once and can be forced again", {
  shared_reset()
  a <- shared_config()
  b <- shared_config()
  expect_identical(a, b)                     # cached, same object contents
  expect_identical(shared_config(), a)
  expect_false(identical(shared_config(force = TRUE), NULL))
  shared_reset()
  expect_equal(shared_config()$series$name, c("user", "policy", "baseline"))
})
