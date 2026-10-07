# Model inference used by POST /predict and POST /validate-trip-start.
# Frame layouts mirror the training recipes (sections 4.1/4.2).

# Fixed policy threshold (section 4.1): P(high-value) > 0.90 is the accept
# rule everywhere -- /predict, the simulated policy trajectory and the
# baseline's model recommendations.
policy_threshold <- 0.90

# Accept/reject policy (AcceptRejectPolicyFitted): returns P(high-value).
policy_probability <- function(frame) {
  workflow <- policy_workflow()
  if (is.null(workflow)) return(NULL)
  probs <- if (policy_prob_is_raw()) {
    # Tailor only adjusts the class threshold (see policy_prob_is_raw()):
    # probabilities equal the raw parsnip output, so forge + fit predict
    # avoids the augment/tailor round trip inside predict.workflow().
    trace <- nzchar(Sys.getenv("API_TRACE"))
    t0 <- if (trace) proc.time()[["elapsed"]]
    forged <- hardhat::forge(
      frame, hardhat::extract_mold(workflow)$blueprint
    )
    if (!is.data.frame(forged)) forged <- forged$predictors
    t1 <- if (trace) proc.time()[["elapsed"]]
    out <- stats::predict(workflows::extract_fit_parsnip(workflow), forged,
      type = "prob")
    if (trace) {
      cat(sprintf("  policy: forge=%dms fit=%dms\n",
        round((t1 - t0) * 1000),
        round((proc.time()[["elapsed"]] - t1) * 1000)), file = stderr())
    }
    out
  } else {
    stats::predict(workflow, frame, type = "prob")
  }
  as.numeric(probs[[".pred_yes"]])
}

# Decision tree (DecisionTreeWfFitted): "yes" when the start is high-value.
# simulation_id and daily_hourly_wage_mean were additional-info columns in
# training; the reference implementation (optimize_trip_start_time) feeds 0.
start_is_high_value <- function(company, datetime, location_id) {
  if (is.null(model_state$tree)) return(NULL)
  frame <- data.frame(
    hvfhs_license_num = company_to_hvfhs(company),
    DOLocationID = as.character(location_id),
    request_datetime = datetime,
    simulation_id = 0,
    daily_hourly_wage_mean = 0,
    stringsAsFactors = FALSE
  )
  classes <- stats::predict(model_state$tree, frame, type = "class")
  identical(as.character(classes[[".pred_class"]]), "yes")
}
