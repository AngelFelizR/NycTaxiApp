# Response-body conformance with contract/openapi.yaml (ADR-0006).
#
# integration/ proves that the API exposes the paths the contract documents and
# that the clients call them; nothing proved that a body still has the shape
# the contract promises. Rename a field, loosen a type, drop a required key and
# every other test stays green. This file closes that gap by driving the real
# handlers and checking each response -- status and body -- against the schema
# the contract declares for exactly that route and code.
#
# Checking the status too is deliberate: a status the contract does not
# document is the drift nobody notices until a client branches on it.
#
# The two routes with no implementation at all (/trips/sample, /zones/geojson)
# are the known divergence recorded in CHANGELOG and asserted by
# integration/, so there is no response here to check.

test_that("every response the contract documents carries a body schema", {
  doc <- contract_doc()
  checked <- 0L
  undocumented <- character()
  for (p in names(doc$paths)) {
    item <- doc$paths[[p]]
    for (m in intersect(names(item), c("get", "post", "put", "delete", "patch"))) {
      for (code in names(item[[m]]$responses)) {
        checked <- checked + 1L
        schema <- contract_response_schema(m, p, code)
        if (is.na(schema) || identical(schema, "")) {
          undocumented <- c(
            undocumented, sprintf("%s %s -> %s", toupper(m), p, code)
          )
        }
      }
    }
  }
  expect_gt(checked, 0L)
  expect_identical(
    undocumented, character(0),
    label = "responses documented without a JSON body"
  )
})

# A handler that succeeds returns plumber2::Break and leaves the status
# unset, so plumber2 is the one that answers 200. Asserting 200L here would
# assert the wrong thing; what matters is that it did not answer an error.
expect_success <- function(response) {
  expect_true(
    is.null(response$status) ||
      (response$status >= 200L && response$status < 300L),
    label = sprintf("handler answered success (status: %s)",
                    if (is.null(response$status)) "unset" else response$status)
  )
}

# A catch-all 404 has no route to look up, so it is checked against Error
# directly rather than through expect_contract_response().
expect_not_found <- function(response) {
  expect_identical(response$status, 404L)
  expect_contract(response$body, "Error")
}

test_that("the stateless endpoints answer with the promised bodies", {
  old <- snapshot_model_state()
  on.exit(restore_model_state(old), add = TRUE)
  ct <- list("content-type" = "application/json")

  # Nothing loaded: the 503 branch of every model-backed route is documented
  # and is what a cold API really answers, so it is checkable without models.
  set_model_state()
  for (case in list(
    list(handler = predict_handler, route = "/predict",
         payload = list(pulocation_id = 61, dolocation_id = 230,
                        trip_miles = 2.5, trip_time_sec = 1500,
                        driver_pay = 28.5,
                        request_datetime = "2025-01-06T08:30:00Z")),
    list(handler = recommend_start_handler, route = "/recommend-start",
         payload = list(company = "Lyft",
                        datetime = "2025-01-05T16:00:00Z")),
    list(handler = validate_trip_start_handler, route = "/validate-trip-start",
         payload = list(company = "Lyft", datetime = "2025-01-05T16:00:00Z",
                        location_id = 61)),
    list(handler = sensitivity_handler, route = "/sensitivity",
         payload = list(experiment_id = "00000000-0000-0000-0000-000000000000",
                        trip_id = 1L))
  )) {
    response <- fake_response()
    case$handler(fake_request(ct), response, json_raw(case$payload))
    expect_contract_response(response, "POST", case$route)
  }

  response <- fake_response()
  health_handler(response)
  expect_contract_response(response, "GET", "/health")

  # Now loaded enough to answer 200, still without a real model file.
  set_model_state(
    policy_name = "fake",
    valid_hours = data.frame(week_cycle = c(17L, 18L))
  )
  with_accept_all_policy({
    response <- fake_response()
    predict_handler(
      fake_request(ct), response,
      json_raw(list(pulocation_id = 61, dolocation_id = 230,
                    trip_miles = 2.5, trip_time_sec = 1500,
                    driver_pay = 28.5,
                    request_datetime = "2025-01-06T08:30:00Z"))
    )
    expect_success(response)
    expect_contract_response(response, "POST", "/predict")

    response <- fake_response()
    recommend_start_handler(
      fake_request(ct), response,
      json_raw(list(company = "Lyft", datetime = "2025-01-05T16:00:00Z"))
    )
    expect_success(response)
    expect_contract_response(response, "POST", "/recommend-start")
  })

  # /validate-trip-start needs the decision tree; the fixture tree plus a
  # stubbed start_is_high_value is what the endpoint tests already use.
  set_model_state(
    tree = structure(list(), class = "fake_tree"),
    valid_hours = data.frame(week_cycle = c(17L, 18L))
  )
  local_mocked_bindings(start_is_high_value = function(...) TRUE,
                        .package = "taxiapi")
  response <- fake_response()
  validate_trip_start_handler(
    fake_request(ct), response,
    json_raw(list(company = "Lyft", datetime = "2025-01-05T16:00:00Z",
                  location_id = 61))
  )
  expect_success(response)
  expect_contract_response(response, "POST", "/validate-trip-start")

  # Catch-all: no route, so no status to look up.
  response <- fake_response()
  response$body <- ""
  not_found_handler(fake_request(ct), response)
  expect_not_found(response)
})

test_that("the experiment endpoints answer with the promised bodies", {
  with_api_db({
    # GET /health with a pool and every model flag set: the 200 branch.
    old <- snapshot_model_state()
    on.exit(restore_model_state(old), add = TRUE)
    set_model_state(policy_name = "p", tree = "t", valid_hours = "v")
    health <- fake_response()
    health_handler(health)
    expect_identical(health$status, 200L)
    expect_contract_response(health, "GET", "/health")
    restore_model_state(old)
    model_state$policy_name <- "fake" # with_api_db's contract for the rest

    created <- create_exp()
    expect_identical(created$status, 201L)
    expect_contract_response(created, "POST", "/experiments")
    id <- created$body$experiment_id
    resume <- created$body$resume_code
    on.exit(drop_experiment(id), add = TRUE)

    # Missing resume code: 403 before anything else happens.
    forbidden <- fake_response()
    get_experiment_handler(fake_request(exp_headers()), forbidden, id)
    expect_contract_response(forbidden, "GET", "/experiments/{id}")

    got <- fake_response()
    get_experiment_handler(fake_request(exp_headers(resume = resume)), got, id)
    expect_contract_response(got, "GET", "/experiments/{id}")

    state <- fake_response()
    get_state_handler(fake_request(exp_headers(resume = resume)), state, id)
    expect_contract_response(state, "GET", "/experiments/{id}/state")

    decision <- fake_response()
    create_decision_handler(
      fake_request(exp_headers(resume = resume)), decision, id,
      json_raw(list(trip_id = state$body$next_trip$trip_id, accepted = TRUE))
    )
    expect_contract_response(decision, "POST", "/experiments/{id}/decisions")

    feedback <- fake_response()
    feedback_handler(
      fake_request(exp_headers(resume = resume)), feedback, id,
      json_raw(list(rating = 5L, public = TRUE))
    )
    expect_contract_response(feedback, "POST", "/experiments/{id}/feedback")

    share_email <- fake_response()
    share_email_handler(
      fake_request(exp_headers(resume = resume)), share_email, id,
      json_raw(list())
    )
    expect_contract_response(share_email, "POST", "/experiments/{id}/share-email")

    # Play the day out: finish is the only thing that produces a result.
    play_day(id, resume, random_test_ip())
    finished <- fake_response()
    finish_experiment_handler(
      fake_request(exp_headers(resume = resume)), finished, id
    )
    expect_contract_response(finished, "POST", "/experiments/{id}/finish")

    # Second finish and a decision on a closed day: both 409, both documented.
    again <- fake_response()
    finish_experiment_handler(fake_request(exp_headers(resume = resume)), again, id)
    expect_contract_response(again, "POST", "/experiments/{id}/finish")

    late <- fake_response()
    create_decision_handler(
      fake_request(exp_headers(resume = resume)), late, id,
      json_raw(list(trip_id = 1L, accepted = TRUE))
    )
    expect_contract_response(late, "POST", "/experiments/{id}/decisions")

    share <- fake_response()
    share_data_handler(
      fake_request(exp_headers(resume = resume)), share, created$body$share_token
    )
    expect_contract_response(share, "GET", "/share-data/{token}")

    abandoned <- fake_response()
    abandon_experiment_handler(
      fake_request(exp_headers(resume = resume)), abandoned, id
    )
    expect_contract_response(abandoned, "POST", "/experiments/{id}/abandon")

    email <- test_email("contract")
    on.exit(drop_waitlist(email), add = TRUE)
    waitlist <- fake_response()
    waitlist_handler(fake_request(exp_headers()), waitlist,
                     json_raw(list(email = email)))
    expect_contract_response(waitlist, "POST", "/waitlist")

    metrics <- fake_response()
    metrics_handler(fake_request(exp_headers()), metrics)
    expect_contract_response(metrics, "GET", "/metrics")

    unknown <- fake_response()
    unknown$body <- ""
    not_found_handler(fake_request(exp_headers()), unknown)
    expect_not_found(unknown)
  })
})
