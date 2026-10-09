# The median day, from the database (section 8 asks for it and says so with
# "the median day is SQL"): a day is `finished_at - created_at`, and the
# number belongs to the days the load run actually finished, so the window
# comes from the environment rather than from "everything in the table".
#
# Run from the repository root with the API's shell -- it is the environment
# that already carries RPostgres and the credentials the API itself uses:
#
#   LOAD_START=... LOAD_END=... \
#     nix-shell api/default.dev.nix --run "Rscript app/dev/median_day.R"
#
# Output is one machine-readable line, because the caller is a shell script
# and a table would have to be parsed twice. A window with no finished day is
# not an error (the caller says so): it happens when every session failed
# before /finish, and that failure is reported by the assertions elsewhere.
start <- Sys.getenv("LOAD_START")
end <- Sys.getenv("LOAD_END")
if (!nzchar(start) || !nzchar(end)) {
  stop("LOAD_START and LOAD_END are required (ISO-8601 instants).")
}

con <- DBI::dbConnect(
  RPostgres::Postgres(),
  host = Sys.getenv("POSTGRES_HOST"),
  port = as.integer(Sys.getenv("POSTGRES_PORT")),
  dbname = Sys.getenv("POSTGRES_DB"),
  user = Sys.getenv("POSTGRES_USER"),
  password = Sys.getenv("POSTGRES_PASSWORD")
)
on.exit(DBI::dbDisconnect(con), add = TRUE)

row <- DBI::dbGetQuery(con, paste0(
  "SELECT count(*) AS n,",
  "       percentile_cont(0.5) WITHIN GROUP (ORDER BY",
  "         EXTRACT(EPOCH FROM (finished_at - created_at))) AS median_s",
  "  FROM experiments",
  " WHERE status = 'finished'",
  "   AND finished_at >= '", start, "'",
  "   AND finished_at <= '", end, "'"
))

n <- as.integer(row$n[1])
median_s <- if (n > 0) as.numeric(row$median_s[1]) else NA_real_
cat(sprintf(
  "median_day n=%d median_s=%s\n",
  n,
  if (is.na(median_s)) "NA" else sprintf("%.1f", median_s)
))
