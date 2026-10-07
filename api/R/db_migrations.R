# Schema bootstrap (phase 3, section 5.1): 001_init.sql is written with
# CREATE ... IF NOT EXISTS, so applying it at startup is idempotent and a
# fresh database (CI, production) comes up without a manual step. The dev
# database already has the tables; re-running them is a no-op.
#
# The repo root is set by the entrypoint (plumber.R) and by
# tests/testthat/helper-load.R, so both the API process and the test process
# resolve api/migrations/ the same way.

schema_ready <- function() isTRUE(model_state$schema_ready)

# Applies every *.sql in api/migrations/ in filename order. Returns TRUE when
# the schema is usable; logs and returns FALSE on error so the API can still
# start (handlers answer 503 until the database is fixed).
ensure_schema <- function(pool) {
  model_state$schema_ready <- FALSE
  if (is.null(pool)) return(FALSE)
  root <- model_state$repo_root
  if (is.null(root)) {
    message("migrations: model_state$repo_root is not set")
    return(FALSE)
  }
  dir <- file.path(root, "api", "migrations")
  files <- sort(list.files(dir, pattern = "\\.sql$", full.names = TRUE))
  if (length(files) == 0) {
    message("migrations: no .sql files under ", dir)
    return(FALSE)
  }
  apply_file <- function(file) {
    sql <- readLines(file, warn = FALSE)
    # Strip every "-- ..." tail before splitting on ";": an inline comment may
    # itself contain a semicolon ("-- SHA-256(...); never a clear IP") and
    # would cut the statement in half. The files have no function bodies and
    # no dollar-quoted strings, so dropping from "--" to end of line is safe.
    sql <- sub("--.*$", "", sql)
    stmts <- trimws(strsplit(paste(sql, collapse = "\n"), ";", fixed = TRUE)[[1]])
    stmts <- stmts[nzchar(stmts)]
    con <- pool::poolCheckout(pool)
    on.exit(pool::poolReturn(con), add = TRUE)
    for (stmt in stmts) DBI::dbExecute(con, stmt)
    TRUE
  }
  for (file in files) {
    ok <- tryCatch(
      apply_file(file),
      error = function(e) {
        message("migrations: ", basename(file), " failed: ", conditionMessage(e))
        FALSE
      }
    )
    if (!isTRUE(ok)) return(FALSE)
  }
  model_state$schema_ready <- TRUE
  TRUE
}
