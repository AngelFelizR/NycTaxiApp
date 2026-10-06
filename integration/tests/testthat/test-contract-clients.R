# The two clients are the only callers of the API (5.10), so what they ask for
# has to exist: in the contract first, and in the API second. A path that only
# one of the three knows about is a bug that surfaces as a 404 in production.

test_that("app/R/api_client.R only calls paths the contract documents", {
  called <- client_paths("app/R/api_client.R")
  doc <- contract_paths("openapi.yaml")
  expect_gt(length(called), 5)
  expect_equal(setdiff(norm_params(called), norm_params(doc)), character(),
               label = "paths missing from contract/openapi.yaml")
})

test_that("share/R/api_client.R only calls paths the contract documents", {
  called <- client_paths("share/R/api_client.R")
  doc <- contract_paths("openapi.yaml")
  expect_gt(length(called), 0)
  expect_equal(setdiff(norm_params(called), norm_params(doc)), character(),
               label = "paths missing from contract/openapi.yaml")
})

test_that("everything either client calls is also implemented", {
  called <- c(client_paths("app/R/api_client.R"),
              client_paths("share/R/api_client.R"))
  implemented <- registered_routes("api/plumber.R")
  expect_equal(setdiff(norm_params(called), norm_params(implemented)),
               character(),
               label = "client paths with no route in api/plumber.R")
})

test_that("the contracts keep the shapes the clients build", {
  # The app addresses experiments as /experiments/{id}/... and the contract
  # spells the parameter {id} -- routr's <id> never reaches the client.
  expect_true("/experiments/{param}" %in% client_paths("app/R/api_client.R") ||
                "/experiments/{param}/state" %in% client_paths("app/R/api_client.R"))
  expect_equal(client_paths("share/R/api_client.R"),
               c("/share-data/{param}", "/waitlist"))
})
