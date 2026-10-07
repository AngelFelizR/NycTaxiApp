# Every variable a service reads at runtime has to be in .env.example, or the
# next person to deploy it discovers the setting by reading the source. This
# is the same drift check as the contract tests, one layer down.

# Scanned: the three services plus the offline tools, including their entry
# scripts (api/plumber.R and share/plumber.R read API_HOST / SHARE_HOST), but
# never tests/ or dev/ -- those are not deployed and they invent variables of
# their own (EMPTY_LIKE, FOO_FROM_ENV) to exercise load_dotenv().

# Read from the environment but never from .env: these are exported by the Nix
# shells and by the Dockerfiles, because libgomp/OpenBLAS have to see them when
# R starts rather than after (section 4.1).
NOT_FROM_DOTENV <- c(
  "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"
)

read_env_example <- function() {
  f <- file.path(repo_root, ".env.example")
  expect_true(file.exists(f), label = ".env.example")
  lines <- readLines(f, warn = FALSE)
  sub("=.*$", "", grep("^[A-Z0-9_]+=", lines, value = TRUE))
}

vars_read_in_code <- function() {
  roots <- c("api", "app", "share", "tools")
  files <- unlist(lapply(roots, function(d) {
    list.files(file.path(repo_root, d), pattern = "[.][rR]$",
                recursive = TRUE, full.names = TRUE)
  }))
  files <- files[!grepl("/(tests|dev)/", files)]
  out <- character()
  for (f in files) {
    txt <- paste(readLines(f, warn = FALSE), collapse = "\n")
    # gregexpr() already returns a list (one entry per input string).
    m <- gregexpr('Sys\\.getenv\\("([A-Z0-9_]+)"', txt, perl = TRUE)
    hits <- regmatches(txt, m)[[1]]
    if (length(hits) > 0) {
      out <- c(out, sub('^Sys\\.getenv\\("([A-Z0-9_]+)"$', "\\1", hits))
    }
  }
  sort(unique(out))
}

test_that("every variable the services read is documented in .env.example", {
  documented <- read_env_example()
  used <- setdiff(vars_read_in_code(), NOT_FROM_DOTENV)
  expect_gt(length(used), 10)
  missing <- setdiff(used, documented)
  expect_equal(missing, character(),
               label = "variables read in R/ but absent from .env.example")
})

test_that(".env.example does not document variables nothing reads", {
  documented <- read_env_example()
  used <- vars_read_in_code()
  # Exceptions, each for a reason:
  #  - read from YAML with ${...} rather than Sys.getenv(), by the compose
  #    files or by docker-compose.prod.yml;
  #  - CF_API_TOKEN: required by the master document's phase-0 prompt and used
  #    by whoever automates the section 8.4 Cloudflare rule later.
  from_yaml <- c("MODELS_DIR", "DATA_DIR", "POSTGRES_USER", "POSTGRES_DB",
                 "CF_API_TOKEN")
  unused <- setdiff(documented, c(used, from_yaml))
  expect_equal(unused, character(),
               label = ".env.example entries no code reads")
})
