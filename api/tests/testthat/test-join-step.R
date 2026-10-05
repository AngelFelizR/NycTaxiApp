spatial_fixture <- function() {
  data.frame(
    LocationID = c(1, 2, 61),
    Borough = c("Manhattan", "Bronx", "Queens"),
    service_zone = c("sz1", "sz2", "sz3"),
    stringsAsFactors = FALSE
  )
}

test_that("prefixed join mirrors the data.table x[i] semantics", {
  main <- data.frame(
    PU_LocationID = c(61, 999),
    DO_LocationID = c(2, 1),
    v = c(10, 20),
    stringsAsFactors = FALSE
  )
  rec <- recipes::recipe(~ ., data = main) |>
    step_join_geospatial_features(
      PU_LocationID, DO_LocationID,
      spatial_features = spatial_fixture(),
      col_prefix = c("PU_", "DO_")
    ) |>
    recipes::prep()
  out <- recipes::bake(rec, main)

  # Column order mirrors the original loop: last prefix block first, then
  # the earlier prefix block, then new_data without the join keys.
  expect_identical(
    names(out),
    c(
      "DO_LocationID", "DO_Borough", "DO_service_zone",
      "PU_LocationID", "PU_Borough", "PU_service_zone",
      "v"
    )
  )
  # Matched rows: key column takes new_data's value, the rest from the
  # spatial table.
  expect_identical(out$PU_LocationID, c(61, 999))
  expect_identical(out$PU_Borough, c("Queens", NA_character_))
  expect_identical(out$DO_LocationID, c(2, 1))
  expect_identical(out$DO_Borough, c("Bronx", "Manhattan"))
  expect_identical(out$v, c(10, 20))
})

test_that("plain (no prefix) join keeps new_data's key and appends features", {
  main <- data.frame(
    LocationID = c(61, 999, 1),
    v = c(10, 20, 30),
    stringsAsFactors = FALSE
  )
  rec <- recipes::recipe(~ ., data = main) |>
    step_join_geospatial_features(
      LocationID,
      spatial_features = spatial_fixture()
    ) |>
    recipes::prep()
  out <- recipes::bake(rec, main)

  expect_identical(
    names(out),
    c("LocationID", "Borough", "service_zone", "v")
  )
  expect_identical(out$LocationID, c(61, 999, 1))
  expect_identical(out$Borough, c("Queens", NA_character_, "Manhattan"))
  expect_identical(out$v, c(10, 20, 30))
})

test_that("prep rejects terms that are not present in spatial_features", {
  main <- data.frame(unknown_col = 1, stringsAsFactors = FALSE)
  rec <- recipes::recipe(~ ., data = main) |>
    step_join_geospatial_features(
      unknown_col,
      spatial_features = spatial_fixture(),
      col_prefix = c("PU_")
    )
  expect_error(recipes::prep(rec), "cannot be found")
})
