#!/usr/bin/env Rscript
# NYC Taxi share service -- plumber2 entrypoint (sections 5.10 and 7).
#
# Public on purpose: LinkedIn and X fetch the <head> and the PNG without any
# credentials, so this service must be reachable from the internet while the
# API stays on the private network. It holds no database credentials and no
# models -- every number comes from GET /share-data/{token}.
#
#   nix-shell share/default.dev.nix --run "Rscript share/plumber.R"

args_all <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- if (length(args_all) > 0) {
  sub("^--file=", "", args_all[1])
} else {
  file.path("share", "plumber.R")
}
root <- normalizePath(file.path(dirname(script_path), ".."))

# shared/*.yaml before anything that renders: the card and the page take their
# curve spec and brand palette from there (docs/decisions/0003).
source(file.path(root, "shared", "load.R"))
source(file.path(root, "share", "R", "utils.R"))
load_dotenv(file.path(root, ".env"))

suppressPackageStartupMessages({
  library(plumber2)
  library(httr2)
  library(jsonlite)
  library(reqres)
  library(ggplot2)
  library(patchwork)
  library(ragg)
  library(redux)
})

for (rel in c("R/api_client.R", "R/cache.R", "R/bots.R", "R/render_png.R",
              "R/render_html.R", "R/routes.R")) {
  source(file.path(root, "share", rel))
}

host <- Sys.getenv("SHARE_HOST", "0.0.0.0")
port <- as.integer(Sys.getenv("SHARE_PORT", "8020"))
api <- share_api(host, port)

rss_kb <- as.integer(sub(".*:\\s+([0-9]+) kB.*", "\\1",
  grep("VmRSS", readLines("/proc/self/status"), value = TRUE)[1]))
message(
  "NYC Taxi share listening on ", host, ":", port,
  " | base URL ", share_base_url(),
  " | RSS ", round(rss_kb / 1024), " MB"
)

plumber2::api_run(api, host = host, port = port, block = TRUE, silent = FALSE)
