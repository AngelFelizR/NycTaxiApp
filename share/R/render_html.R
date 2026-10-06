# The public share page (section 7.2): static HTML with Open Graph in the
# <head> and a visible body -- LinkedIn and X read the head without
# JavaScript, humans read the body. Nothing here is cached at the edge, so
# the view counter can see the request; only the PNG carries a long
# Cache-Control (7.1).

# Every string the page renders, in one place, so tests and production cannot
# drift (6.6). Shapes follow the worked example in contract/share.openapi.yaml:
# the day labels the page, `label` is the verdict shown on the card (and here
# as the image alt text plus a visible line), `share_text` is the description.
share_copy <- function(data) {
  day <- as.character(data$day_label %||% "")[1]
  if (is.na(day)) day <- ""
  verdict <- trimws(as.character(data$label %||% "")[1])
  if (is.na(verdict)) verdict <- ""
  list(
    day = day,
    title = sprintf("NYC Taxi Decision Simulator - %s", day),
    verdict = verdict,
    description = data$share_text %||% "",
    play = "Play your own day",
    # A credit line that also names what the visitor is looking at.
    context = sprintf(
      "%s drove %d trips in a simulated 8-hour NYC shift and earned %s/h.",
      if (nzchar(day)) day else "A driver",
      as.integer(data$trips_accepted %||% 0L),
      show_num(data$final_user_wage, 2, prefix = "$")
    ),
    ranking = if (is.null(data$user_percentile) || is.na(data$user_percentile)) {
      ""
    } else {
      sprintf("Ranked at the %s percentile of 1,000 simulated model days.",
              ordinal(data$user_percentile))
    },
    footer = "A simulated day, not a real one. One sample is one sample."
  )
}

share_page <- function(data, token) {
  base <- share_base_url()
  share_url <- paste0(base, "/share/", token)
  png_url <- paste0(share_url, ".png")
  play_url <- paste0(base, "/?ref=share")
  cpy <- share_copy(data)

  meta <- paste0(
    '<meta property="og:title" content="', html_escape(cpy$title), '">\n',
    '<meta property="og:description" content="', html_escape(cpy$description), '">\n',
    '<meta property="og:image" content="', png_url, '">\n',
    '<meta property="og:image:width" content="1200">\n',
    '<meta property="og:image:height" content="630">\n',
    '<meta property="og:url" content="', share_url, '">\n',
    '<meta name="twitter:card" content="summary_large_image">\n',
    '<meta name="twitter:title" content="', html_escape(cpy$title), '">\n',
    '<meta name="twitter:description" content="', html_escape(cpy$description), '">\n',
    '<meta name="twitter:image" content="', png_url, '">'
  )

  paste0(
    "<!doctype html>\n",
    '<html lang="en">\n<head>\n<meta charset="utf-8">\n',
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
    "<title>", html_escape(cpy$title), "</title>\n",
    meta, "\n",
    "<style>\n",
    "  :root { --ink:#1f2328; --muted:#64748b; --line:#e3e6ea; --bg:#f6f7f9; }\n",
    "  * { box-sizing: border-box; }\n",
    "  body { margin:0; background:var(--bg); color:var(--ink);\n",
    "         font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;\n",
    "         line-height:1.5; }\n",
    "  main { max-width: 640px; margin: 0 auto; padding: 32px 16px 48px; }\n",
    "  .card { background:#fff; border:1px solid var(--line); border-radius:14px;\n",
    "          overflow:hidden; box-shadow:0 1px 3px rgba(0,0,0,.06); }\n",
    "  .card img { display:block; width:100%; height:auto; }\n",
    "  h1 { font-size:1.4rem; margin:24px 0 2px; }\n",
    "  .verdict { font-size:1.15rem; font-weight:700; margin:0 0 4px; }\n",
    "  .context { color:var(--muted); margin:0 0 20px; font-size:.95rem; }\n",
    "  .ranking { color:var(--muted); font-size:.9rem; margin:14px 0 0; }\n",
    "  .cta { display:inline-block; margin-top:20px; padding:12px 22px;\n",
    "         background:", brand_colour(),
    "; color:#fff; text-decoration:none;\n",
    "         border-radius:10px; font-weight:600; }\n",
    "  .cta:hover { background:#5a4be0; }\n",
    "  footer { color:var(--muted); font-size:.8rem; margin-top:28px; }\n",
    "</style>\n",
    "</head>\n<body>\n<main>\n",
    '<div class="card"><img src="', png_url,
    '" alt="',
    html_escape(if (nzchar(cpy$verdict)) cpy$verdict else cpy$title),
    '" width="1200" height="630"></div>\n',
    "<h1>", html_escape(cpy$day), "</h1>\n",
    if (nzchar(cpy$verdict)) {
      paste0('<p class="verdict">', html_escape(cpy$verdict), "</p>\n")
    } else {
      ""
    },
    '<p class="context">', html_escape(cpy$context), "</p>\n",
    '<a class="cta" href="', play_url, '">', html_escape(cpy$play), "</a>\n",
    if (nzchar(cpy$ranking)) {
      paste0('<p class="ranking">', html_escape(cpy$ranking), "</p>\n")
    } else {
      ""
    },
    "<footer>", html_escape(cpy$footer), "</footer>\n",
    "</main>\n</body>\n</html>\n"
  )
}
