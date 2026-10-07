# GET /health (contract operationId getHealth): pool state plus model load
# flags for the Docker healthcheck probe. 503 when the database is down or a
# required model is missing.

health_handler <- function(response) {
  database <- db_status()
  models <- models_status()
  healthy <- identical(database$status, "ok") &&
    isTRUE(models$policy) &&
    isTRUE(models$start_validator) &&
    isTRUE(models$valid_hours)

  response$status <- if (healthy) 200L else 503L
  response$body <- list(
    status = if (healthy) "ok" else "unavailable",
    database = database,
    models = models,
    model_version = Sys.getenv("MODEL_VERSION", "0.0.1-data"),
    app_version = Sys.getenv("APP_VERSION", "0.1.0")
  )
  plumber2::Break
}
