# Boot helpers for test-routes.R: a free TCP port, a stand-in for the private
# API, and the two background processes. Sourced both by the tests (parent)
# and by the children, so everything a child needs must be reachable from
# helper-load.R + this file.

# Port probe. NOT socketConnection(server = TRUE): R blocks in accept() there
# even with blocking = FALSE, and the probe would hang the whole suite. Reading
# the kernel's own listen table is exact and non-blocking.
listening_ports <- function() {
  read_tbl <- function(path) {
    l <- readLines(path, warn = FALSE)
    if (length(l) < 2) return(character())
    fields <- strsplit(trimws(l[-1]), "[[:space:]]+")
    loc <- vapply(fields, function(f) if (length(f) >= 4) f[2] else "", "")
    st  <- vapply(fields, function(f) if (length(f) >= 4) f[4] else "", "")
    loc[st == "0A"]                      # 0A = TCP_LISTEN
  }
  loc <- unique(c(tryCatch(read_tbl("/proc/net/tcp"), error = function(e) character()),
                  tryCatch(read_tbl("/proc/net/tcp6"), error = function(e) character())))
  if (!length(loc)) return(integer())
  as.integer(strtoi(sub("^[^:]*:", "", loc), 16L))
}

# Ports handed out during one test run, so the stub and the service cannot
# land on the same number.
taken <- new.env(parent = emptyenv())

free_port <- function() {
  for (i in 1:200) {
    p <- sample(20000:45000, 1)
    if (exists(as.character(p), envir = taken, inherits = FALSE)) next
    if (p %in% listening_ports()) next
    assign(as.character(p), TRUE, envir = taken)
    return(p)
  }
  stop("could not find a free TCP port")
}

# Only the two routes share knows (5.10). It answers the fixture for the one
# token the tests use and 404 for everything else.
#
# NOTE: handlers hand plumber2 a *list*, never a JSON string -- the
# serializer is what encodes, and passing pre-encoded text would wrap the
# whole document in a JSON string.
stub_api <- function(port, token) {
  fixture <- share_fixture()
  not_found <- list(error = "not_found", message = "Not found.")
  json <- list("application/json" = plumber2::format_unboxed())
  app <- plumber2::api(host = "127.0.0.1", port = port)
  app <- plumber2::api_get(app, "/share-data/<t>", function(request, response, t) {
    if (identical(t, token)) {
      response$body <- fixture
    } else {
      response$status <- 404L
      response$body <- not_found
    }
    plumber2::Break
  }, serializers = json)
  app <- plumber2::api_post(app, "/waitlist", function(request, response, b) {
    response$body <- list(message = "You are on the waitlist.")
    plumber2::Break
  }, serializers = json,
  parsers = list("application/json" = function(raw, d) raw,
                 "*/*" = function(raw, d) raw))
  plumber2::api_any(app, "/*", function(request, response) {
    response$status <- 404L
    response$body <- not_found
    plumber2::Break
  }, serializers = json)
}

start_stub <- function(port, share_dir, token) {
  callr::r_bg(function(port, share_dir, token) {
    source(file.path(share_dir, "tests", "testthat", "helper-load.R"))
    source(file.path(share_dir, "tests", "testthat", "helper-boot.R"))
    plumber2::api_run(stub_api(port, token), host = "127.0.0.1",
                      port = port, block = TRUE, silent = TRUE)
  }, args = list(port = port, share_dir = share_dir, token = token),
  stdout = "|", stderr = "|")
}

# Wait until a child actually serves, instead of a fixed sleep: a cold R start
# has to load plumber2, ggplot2, patchwork and ragg before api_run() binds.
wait_for <- function(url, proc = NULL, tries = 30) {
  for (i in seq_len(tries)) {
    if (!is.null(proc) && !proc$is_alive()) return(FALSE)
    ready <- tryCatch({
      r <- httr2::request(url) |>
        httr2::req_timeout(2) |>
        httr2::req_error(is_error = ~ FALSE)
      httr2::resp_status(httr2::req_perform(r)) < 500L
    }, error = function(e) FALSE)
    if (isTRUE(ready)) return(TRUE)
    Sys.sleep(1)
  }
  FALSE
}

start_share <- function(port, share_dir) {
  callr::r_bg(function(port, share_dir) {
    source(file.path(share_dir, "tests", "testthat", "helper-load.R"))
    plumber2::api_run(share_api("127.0.0.1", port), host = "127.0.0.1",
                      port = port, block = TRUE, silent = TRUE)
  }, args = list(port = port, share_dir = share_dir),
  stdout = "|", stderr = "|")
}
