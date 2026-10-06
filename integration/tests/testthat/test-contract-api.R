# contract/openapi.yaml is the authoritative description of the API (AGENTS:
# "toda implementación nueva se contrasta aquí"). These tests are the tripwire
# that keeps the three descriptions -- contract, routes, clients -- from
# drifting apart.

test_that("every route the API registers is documented", {
  api <- registered_routes("api/plumber.R")
  doc <- contract_paths("openapi.yaml")
  expect_gt(length(api), 10)
  undocumented <- setdiff(norm_params(api), norm_params(doc))
  expect_equal(undocumented, character(),
               label = "routes missing from contract/openapi.yaml")
})

test_that("share/ registers exactly the three public routes plus /health", {
  api <- registered_routes("share/R/routes.R")
  doc <- contract_paths("share.openapi.yaml")
  # The contract says it out loud: "GET /health exists for the container
  # healthcheck but is not part of the public surface" -- so it is registered
  # and deliberately undocumented. Everything else has to line up.
  expect_equal(api, sort(c(doc, "/health")))
})

# The master document's section 5.2 lists 18 endpoints and the contract has
# 18; the API implements 16. Both missing ones have no client:
#   /zones/geojson -- section 6.1.3 has the app preload the zones from the
#                     read-only data volume instead, so the route would have
#                     no caller ("la app no espera red para pintar").
#   /trips/sample   -- nothing in app/ or share/ ever asks for it.
# This is recorded rather than silently allowed: when either is implemented or
# dropped from the contract, this test fails and forces the decision.
test_that("the documented-but-unimplemented set is exactly the two known ones", {
  api <- registered_routes("api/plumber.R")
  doc <- contract_paths("openapi.yaml")
  expect_equal(setdiff(norm_params(doc), norm_params(api)),
               c("/trips/sample", "/zones/geojson"))
})

test_that("the contract is well formed", {
  for (f in c("openapi.yaml", "share.openapi.yaml")) {
    doc <- yaml::read_yaml(file.path(repo_root, "contract", f))
    expect_equal(doc$openapi, "3.1.0", label = f)

    ids <- character()
    for (p in doc$paths) {
      for (verb in intersect(c("get", "post", "put", "delete", "patch"),
                              names(p))) {
        op <- p[[verb]]
        expect_true(length(op$responses) > 0,
                    label = paste(f, verb, "declares responses"))
        expect_true(nzchar(op$operationId %||% ""),
                    label = paste(f, verb, "has an operationId"))
        ids <- c(ids, op$operationId)
      }
    }
    # Duplicate operationIds make the generated docs and any codegen ambiguous.
    expect_false(anyDuplicated(ids) > 0,
                 label = paste(f, "operationIds are unique"))
  }
})
