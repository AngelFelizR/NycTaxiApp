# Bot filter (7.4): crawlers that only render the card are not visitors, and
# a missing User-Agent is a script rather than a person.

test_that("known crawlers are not counted", {
  expect_true(is_bot("LinkedInBot/1.0 (+https://www.linkedin.com)"))
  expect_true(is_bot("Twitterbot/1.0"))
  expect_true(is_bot("facebookexternalhit/1.1"))
  expect_true(is_bot("WhatsApp/2.23 H"))
  expect_true(is_bot("curl/8.4.0"))
  expect_true(is_bot("python-requests/2.31"))
  expect_true(is_bot("HeadlessChrome/154"))
})

test_that("a missing or blank User-Agent is not a visitor", {
  expect_true(is_bot(""))
  expect_true(is_bot("   "))
  expect_true(is_bot(NULL))
  expect_true(is_bot(NA_character_))
})

test_that("real browsers and the social apps' in-app browsers count", {
  expect_false(is_bot(paste0(
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ",
    "(KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36")))
  expect_false(is_bot("LinkedInApp/1.0"))
  # Case-insensitive: a mixed-case token must still match.
  expect_true(is_bot("TWITTERBOT/1.0"))
})
