# The card (7.1): 1200x630, three curves, one label, no PII and no
# experiment_id -- only what GET /share-data already aggregated.

TOKEN <- "aZ3kQ9mLp1Rt"

png_info <- function(bytes) {
  stopifnot(is.raw(bytes), length(bytes) > 24)
  # IHDR is the first chunk: width and height are big-endian at offset 16/20.
  w <- sum(as.integer(bytes[17:20]) * c(16777216, 65536, 256, 1))
  h <- sum(as.integer(bytes[21:24]) * c(16777216, 65536, 256, 1))
  list(width = w, height = h)
}

test_that("share_png returns a 1200x630 PNG", {
  bytes <- share_png(share_fixture())
  expect_true(is.raw(bytes))
  expect_gt(length(bytes), 5000)
  # PNG magic number.
  expect_identical(as.integer(bytes[1:4]), c(137L, 80L, 78L, 71L))
  info <- png_info(bytes)
  expect_equal(info$width, 1200L)
  expect_equal(info$height, 630L)
})

test_that("every outcome renders, including the neutral custom-seed one", {
  for (out in c("beat_model", "tied_model", "beat_baseline",
                "lost_to_baseline", "no_rides")) {
    bytes <- share_png(share_fixture(outcome = out))
    expect_identical(as.integer(bytes[1:4]), c(137L, 80L, 78L, 71L),
                     label = out)
  }
  unofficial <- share_png(share_fixture(outcome = "beat_model",
                                        seed_is_custom = TRUE))
  expect_identical(as.integer(unofficial[1:4]), c(137L, 80L, 78L, 71L))
})

test_that("an empty history still produces a card", {
  bytes <- share_png(share_fixture(history = data.frame(
    step = numeric(), user = numeric(), policy = numeric(), baseline = numeric())))
  expect_identical(as.integer(bytes[1:4]), c(137L, 80L, 78L, 71L))
})

test_that("the card is built from history whether json simplified it or not", {
  rows <- list(list(step = 0, user = 0, policy = 0, baseline = 0),
               list(step = 1, user = 10, policy = 12, baseline = 8))
  long <- share_history_long(rows)
  expect_equal(nrow(long), 6)                       # 2 steps x 3 curves
  expect_setequal(as.character(long$series), c("You", "Model", "Accept all"))
  expect_equal(sort(unique(long$step)), c(0, 1))
})

# ---- the spec comes from shared/, not from this file ------------------------

test_that("the card draws from the shared curve spec and brand palette", {
  s <- curve_specs()
  expect_equal(s$name, c("user", "policy", "baseline"))
  expect_equal(s$label, c("You", "Model", "Accept all"))
  expect_true(all(grepl("^#[0-9a-fA-F]{6}$", s$colour)))
  # The legend the card paints is the same one Results paints.
  expect_setequal(as.character(share_history_long(list(
    list(step = 0, user = 0, policy = 0, baseline = 0)))$series),
    unname(curve_labels()))
  # Its colours are named by label, which scale_colour_manual looks up.
  expect_equal(names(curve_colours()), unname(curve_labels()))
})
