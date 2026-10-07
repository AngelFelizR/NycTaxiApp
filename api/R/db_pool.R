# PostgreSQL connection pool (section 5.1). The pool is created in the main
# process; dbPool is lazy, so a database outage is reported by /health as 503
# instead of preventing startup.

create_db_pool <- function() {
  tryCatch(
    pool::dbPool(
      RPostgres::Postgres(),
      host = Sys.getenv("POSTGRES_HOST", "postgres"),
      port = as.integer(Sys.getenv("POSTGRES_PORT", "5432")),
      dbname = Sys.getenv("POSTGRES_DB", "nyctaxi"),
      user = Sys.getenv("POSTGRES_USER", "nyctaxi"),
      password = Sys.getenv("POSTGRES_PASSWORD", ""),
      # Every timestamp in the contract is UTC; without these the connection
      # inherits the container's empty session TimeZone, and RPostgres warns
      # ("Invalid time zone" on write, "Unrecognized time zone ''" on read)
      # while binding and fetching POSIXct columns.
      timezone = "UTC",
      timezone_out = "UTC",
      minSize = 1,
      maxSize = 4
    ),
    error = function(e) {
      message("pool: ", conditionMessage(e))
      NULL
    }
  )
}

db_status <- function() {
  pool <- model_state$pool
  if (is.null(pool)) {
    return(list(status = "error", connections = 0L))
  }
  tryCatch(
    {
      con <- pool::poolCheckout(pool)
      pool::poolReturn(con)
      counters <- pool$counters
      open <- as.integer((counters$free %||% 0) + (counters$taken %||% 0))
      list(status = "ok", connections = open)
    },
    error = function(e) {
      # message() is swallowed during request handling; stderr always lands
      # in the API log.
      cat("db_status ERROR: ", conditionMessage(e), "\n", file = stderr())
      list(status = "error", connections = 0L)
    }
  )
}
