# Bot filter for the share_views counter (section 7.4): the crawlers that
# fetch the card to render it are not visitors, and a bare User-Agent (a
# script, a health check) is not one either. Everything else -- real browsers
# and the LinkedIn/Twitter/X apps that show the unfurled card to a human --
# counts.
#
# The list is matched case-insensitively against the whole User-Agent.
bot_patterns <- c(
  "linkedinbot", "twitterbot", "facebookexternalhit", "slackbot",
  "discordbot", "whatsapp", "telegrambot", "pinterest", "redditbot",
  "embedly", "vkshare", "tumblr", "googlebot", "bingbot", "applebot",
  "headlesschrome", "phantomjs", "lighthouse", "curl/", "wget/",
  "python-requests", "go-http-client", "java/", "libwww"
)

is_bot <- function(user_agent) {
  ua <- tolower(trimws(as.character(user_agent %||% "")[1]))
  if (is.na(ua) || !nzchar(ua)) return(TRUE)   # no UA at all = not a browser
  any(vapply(bot_patterns, function(p) grepl(p, ua, fixed = TRUE), logical(1)))
}
