# Load the three descriptions of the system and the two clients, so the tests
# compare what is actually written rather than what someone remembers.
#
# testthat runs with cwd = integration/tests/testthat, so the repository root
# is three levels up.

repo_root <- normalizePath(file.path("..", "..", ".."))

`%||%` <- function(x, y) if (is.null(x)) y else x

# The contract names the parameter ({id}, {token}) while the client only knows
# the R variable it passes (experiment_id, token). Compare by shape.
norm_params <- function(x) gsub("\\{[^}]+\\}", "{}", x)

contract_paths <- function(file) {
  doc <- yaml::read_yaml(file.path(repo_root, "contract", file))
  sort(names(doc$paths))
}

# Routes as plumber2 sees them: `api_get(api, "/path"` on one line, or with the
# path on the next one (api/plumber.R does both). `<id>` is routr's syntax and
# `{id}` is OpenAPI's, so they are normalised to the contract's.
registered_routes <- function(rel) {
  txt <- paste(readLines(file.path(repo_root, rel), warn = FALSE),
               collapse = "\n")
  m <- gregexpr(
    'api_(?:get|post|put|any|any_header)\\s*\\(\\s*api\\s*,\\s*"([^"]+)"',
    txt, perl = TRUE)
  raw <- regmatches(txt, m)[[1]]
  if (length(raw) == 0) return(character())
  paths <- sub('^.*"([^"]+)"$', "\\1", raw)
  paths <- gsub("<([^>]+)>", "{\\1}", paths)
  # "/*" is the catch-all and the internal-auth hook, not an endpoint.
  sort(unique(setdiff(paths, "/*")))
}

# Paths a client actually calls, read from api_request(ctx, <path>). The first
# argument is either a literal or file.path(<literal>, <variable>, ...), where
# the variable becomes a path parameter.
client_paths <- function(rel) {
  txt <- paste(readLines(file.path(repo_root, rel), warn = FALSE),
               collapse = "\n")
  out <- character()

  lit <- gregexpr('api_request\\(ctx,\\s*"([^"]+)"', txt, perl = TRUE)[[1]]
  hits <- regmatches(txt, list(lit))[[1]]
  if (length(hits) > 0) out <- c(out, sub('^.*"([^"]+)".*$', "\\1", hits))

  fp <- gregexpr('file\\.path\\(([^()]*)\\)', txt, perl = TRUE)[[1]]
  for (seg in regmatches(txt, list(fp))[[1]]) {
    args <- trimws(strsplit(sub("^file\\.path\\((.*)\\)$", "\\1", seg),
                            ",")[[1]])
    bits <- vapply(args, function(x) {
      if (grepl('^"[^"]*"$', x)) gsub('"', "", x) else "{param}"
    }, character(1))
    out <- c(out, paste(bits, collapse = "/"))
  }
  # api_request builds a relative path; the contract documents rooted ones.
  sort(unique(paste0("/", out)))
}
