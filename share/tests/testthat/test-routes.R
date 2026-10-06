# The routes themselves: status codes, cache headers, the view counter and
# the ordering of `/share/{token}.png` in front of `/share/{token}` -- the
# parent pattern would otherwise swallow the suffix and 404 the card.

TOKEN <- "aZ3kQ9mLp1Rt"
UNKNOWN <- "000000000000"
BROWSER <- "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/154.0.0.0"
CRAWLER <- "LinkedInBot/1.0 (+https://www.linkedin.com)"

req <- function(url, ua = NULL) {
  r <- httr2::request(url)
  if (!is.null(ua)) r <- httr2::req_headers(r, "User-Agent" = ua)
  httr2::req_error(httr2::req_timeout(r, 20), is_error = ~ FALSE)
}

test_that("guard rails reject junk before any upstream call", {
  expect_true(valid_email("a@b.co"))
  expect_true(valid_email("  a+tag@sub.example.org  "))
  for (bad in c("", "   ", "nope", "a@b", "@b.co", "a@b.", "a b@c.de",
                strrep("a", 260), "@b.co")) {
    expect_false(valid_email(bad), label = paste0("<", substr(bad, 1, 30), ">"))
  }
  expect_true(valid_token("aZ3kQ9mLp1Rt"))
  for (bad in c("", "short", "aZ3kQ9mLp1Rt!", "aZ3kQ9mLp1Rt.", "aZ3kQ9mLp1Rtxx")) {
    expect_false(valid_token(bad), label = paste0("<", bad, ">"))
  }
  expect_false(valid_token(NA_character_))
})

test_that("every route behaves once booted against a stub API", {
  if (is.null(redis_con())) skip("Redis is not reachable")
  up <- free_port()
  port <- free_port()

  # The children inherit the environment when they are spawned, so the stub
  # URL has to be in place before start_share(), not at request time.
  old_api <- Sys.getenv("TAXI_API_URL", unset = NA)
  on.exit(if (is.na(old_api)) Sys.unsetenv("TAXI_API_URL")
          else Sys.setenv(TAXI_API_URL = old_api), add = TRUE)
  Sys.setenv(TAXI_API_URL = paste0("http://127.0.0.1:", up))

  stub <- start_stub(up, share_dir, TOKEN)
  on.exit(stub$kill(), add = TRUE)
  share <- start_share(port, share_dir)
  on.exit(share$kill(), add = TRUE)
  base <- paste0("http://127.0.0.1:", port)
  if (!wait_for(paste0("http://127.0.0.1:", up, "/share-data/", TOKEN), stub) ||
      !wait_for(paste0(base, "/health"), share)) {
    skip("the service or its stub did not come up")
  }

  views_del(TOKEN); png_cache_del(TOKEN)
  on.exit({ views_del(TOKEN); png_cache_del(TOKEN) }, add = TRUE)
  {

    # ---- health: no upstream needed at all -------------------------------
    h <- req(paste0(base, "/health")) |> httr2::req_perform()
    expect_equal(httr2::resp_status(h), 200L)
    expect_equal(httr2::resp_body_json(h)$status, "ok")

    # ---- GET /share/{token}.png ------------------------------------------
    png <- req(paste0(base, "/share/", TOKEN, ".png")) |> httr2::req_perform()
    expect_equal(httr2::resp_status(png), 200L)
    expect_match(httr2::resp_content_type(png), "image/png")
    expect_match(httr2::resp_header(png, "cache-control"),
                 "max-age=86400, s-maxage=604800")
    bytes <- httr2::resp_body_raw(png)
    expect_identical(as.integer(bytes[1:4]), c(137L, 80L, 78L, 71L))
    expect_gt(length(bytes), 5000)
    # Cached: same bytes back, and the card never reaches disk.
    again <- req(paste0(base, "/share/", TOKEN, ".png")) |> httr2::req_perform()
    expect_equal(httr2::resp_body_raw(again), bytes)

    # ---- GET /share/{token} ------------------------------------------------
    page <- req(paste0(base, "/share/", TOKEN), BROWSER) |> httr2::req_perform()
    expect_equal(httr2::resp_status(page), 200L)
    expect_match(httr2::resp_content_type(page), "text/html")
    expect_equal(httr2::resp_header(page, "cache-control"), "no-store")
    html <- httr2::resp_body_string(page)
    expect_match(html, "<!doctype html>")
    expect_match(html, "og:title")
    expect_match(html, "og:image")
    expect_match(html, "Play your own day")
    expect_false(grepl("<script", html, fixed = TRUE))

    # ---- the view counter only counts humans ------------------------------
    views_del(TOKEN)
    req(paste0(base, "/share/", TOKEN), CRAWLER) |> httr2::req_perform()
    expect_equal(views_get(TOKEN), NA_integer_)
    req(paste0(base, "/share/", TOKEN), BROWSER) |> httr2::req_perform()
    expect_equal(views_get(TOKEN), 1L)

    # ---- unknown tokens and junk paths answer 404 --------------------------
    for (path in c(paste0("/share/", UNKNOWN),
                   paste0("/share/", UNKNOWN, ".png"),
                   "/share/not-a-token",
                   "/nope")) {
      r <- req(paste0(base, path)) |> httr2::req_perform()
      expect_equal(httr2::resp_status(r), 404L, label = path)
      expect_match(httr2::resp_body_string(r), "not_found", fixed = TRUE,
                   label = path)
    }

    # ---- POST /waitlist ----------------------------------------------------
    ok <- httr2::request(paste0(base, "/waitlist")) |>
      httr2::req_body_json(list(email = "a@b.co"), auto_unbox = TRUE) |>
      httr2::req_error(is_error = ~ FALSE) |> httr2::req_perform()
    expect_equal(httr2::resp_status(ok), 200L)
    expect_match(httr2::resp_body_json(ok)$message, "waitlist")

    bad <- httr2::request(paste0(base, "/waitlist")) |>
      httr2::req_body_json(list(email = "nope"), auto_unbox = TRUE) |>
      httr2::req_error(is_error = ~ FALSE) |> httr2::req_perform()
    expect_equal(httr2::resp_status(bad), 422L)
    expect_match(httr2::resp_body_json(bad)$message, "valid email")
  }
})
