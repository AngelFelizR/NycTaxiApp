# Section 12: motion, names for the charts, contrast, and never colour alone.
#
# Everything here is checkable. What §12 leaves to a human -- pa11y, the
# mobile checklist in 390px, and the WebAIM sign-off -- is in the runbook,
# deliberately not in CI (section 10 excludes it too).

contrast_ratio <- function(a, b) {
  # WCAG 2.1 relative luminance (1.4.3 / 1.4.11). AA asks 4.5:1 for body text
  # and 3:1 for large text and graphical objects.
  lin <- function(v) ifelse(v <= 0.03928, v / 12.92, ((v + 0.055) / 1.055)^2.4)
  lum <- function(hex) {
    v <- lin(grDevices::col2rgb(hex)[, 1] / 255)
    0.2126 * v[1] + 0.7152 * v[2] + 0.0722 * v[3]
  }
  l1 <- lum(a)
  l2 <- lum(b)
  (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

test_that("the app honours prefers-reduced-motion", {
  css <- paste(readLines(file.path(app_dir, "www", "styles.css"), warn = FALSE),
               collapse = "\n")
  expect_match(css, "@media \\(prefers-reduced-motion: reduce\\)")
  # The one animation the app owns, plus everything Bootstrap and Leaflet
  # add: durations collapse rather than each being chased individually.
  expect_match(css, "transition-duration: \\.01ms !important")
  expect_match(css, "animation-duration: \\.01ms !important")
})

test_that("both charts carry a name a screen reader can use", {
  for (f in c("mod_results.R", "mod_sensitivity.R")) {
    src <- paste(readLines(file.path(app_dir, "R", f), warn = FALSE),
                 collapse = "\n")
    expect_match(src, 'role = "img"',
                 label = paste(f, "declares role=\"img\""))
    expect_match(src, "aria-label",
                 label = paste(f, "labels its chart"))
  }
  # And the labels are sentences, not the title repeated.
  expect_gt(nchar(label_history_aria), 60)
  expect_gt(nchar(label_sensitivity_aria), 60)
  expect_false(identical(label_history_aria, label_history))
})

test_that("every text pair meets WCAG AA in both themes", {
  text_pairs <- list(
    c("fg", "bg"),            # body copy on the page
    c("fg", "surface"),       # body copy on a card or the sidebar
    c("success_fg", "success_bg"),
    c("danger_fg", "danger_bg"),
    c("primary", "bg")        # links and the preselection outline
  )
  for (mode in c("light", "dark")) {
    p <- taxi_palette(mode)
    for (pair in text_pairs) {
      r <- contrast_ratio(p[[pair[[1]]]], p[[pair[[2]]]])
      expect_gte(
        r, 4.5,
        label = sprintf("%s: %s on %s = %.2f:1",
                        mode, pair[[1]], pair[[2]], r)
      )
    }
  }
})

test_that("the secondary text clears AA on both surfaces, in both themes", {
  # .kpi-label and .kbd-footer are painted with --taxi-muted-fg and sit on the
  # card background and on the surface. One value cannot serve both themes,
  # which is why the token is per mode.
  for (mode in c("light", "dark")) {
    p <- taxi_palette(mode)
    for (bg_name in c("surface", "bg")) {
      r <- contrast_ratio(p$muted_fg, p[[bg_name]])
      expect_gte(
        r, 4.5,
        label = sprintf("muted_fg %s on %s (%s) = %.2f:1",
                        p$muted_fg, bg_name, mode, r)
      )
    }
  }
  # And the stylesheet actually uses the token rather than a literal.
  css <- paste(readLines(file.path(app_dir, "www", "styles.css"), warn = FALSE),
               collapse = "\n")
  expect_match(css, "var(--taxi-muted-fg", fixed = TRUE)
  expect_false(grepl("#64748b", css, fixed = TRUE))
})

test_that("the pending clock says the hours in words, not only in colour", {
  # Section 3.11: no comparative indicator may depend on colour alone, and the
  # one place the UI is tempted is the pending-time bar -- green, amber, red.
  # It also prints the number of hours inside the bar.
  src <- paste(readLines(file.path(app_dir, "R", "mod_trips.R"), warn = FALSE),
               collapse = "\n")
  expect_match(src, 'class = "pending-label"')
  expect_match(src, "textOutput\\(ns\\(\"pending_hours\"\\)")

  # And the three levels are not the only signal the footer offers: the
  # keyboard hints carry their keys as text too.
  expect_match(src, "label_resume_code_btn")
})
