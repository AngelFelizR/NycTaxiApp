# The share page (7.2): static HTML, Open Graph in the head, a visible body
# and never a line of JavaScript.

TOKEN <- "aZ3kQ9mLp1Rt"   # 12 chars, base64url -- the contract's ShareToken

test_that("the head carries the Open Graph tags the crawlers read", {
  html <- share_page(share_fixture(), TOKEN)
  expect_match(html, '<meta property="og:title" content="NYC Taxi Decision Simulator - Day #aZ3kQ9"', fixed = TRUE)
  expect_match(html, '<meta property="og:image" content="https://nyctaxiapp.angelfeliz.com/share/aZ3kQ9mLp1Rt.png"')
  expect_match(html, '<meta property="og:image:width" content="1200"')
  expect_match(html, '<meta property="og:image:height" content="630"')
  expect_match(html, '<meta property="og:url" content="https://nyctaxiapp.angelfeliz.com/share/aZ3kQ9mLp1Rt"')
  expect_match(html, '<meta name="twitter:card" content="summary_large_image"')
  expect_match(html, '<meta property="og:description" content="I beat the model today.')
})

test_that("the body is a real page for humans, with no JavaScript", {
  html <- share_page(share_fixture(), TOKEN)
  expect_match(html, "Play your own day")
  expect_match(html, 'href="https://nyctaxiapp.angelfeliz.com/?ref=share"',
               fixed = TRUE)
  expect_match(html, "<img src=\"https://nyctaxiapp.angelfeliz.com/share/aZ3kQ9mLp1Rt.png\"",
               fixed = TRUE)
  expect_match(html, "<h1>Day #aZ3kQ9</h1>", fixed = TRUE)
  # The verdict is alt text AND a visible line: a crawler that ignores images
  # and a human with images blocked both still get it.
  expect_match(html, 'alt="I beat the Model!"', fixed = TRUE)
  expect_match(html, '<p class="verdict">I beat the Model!</p>', fixed = TRUE)
  expect_false(grepl("<script", html, fixed = TRUE))
  # Mobile-first (6.1.6): the layout has to work at 390px.
  expect_match(html, "width=device-width, initial-scale=1")
})

test_that("the ranking line only appears when there is a percentile", {
  with_rank <- share_page(share_fixture(user_percentile = 73), TOKEN)
  expect_match(with_rank, "73rd percentile")
  no_rank <- share_page(share_fixture(user_percentile = NA), TOKEN)
  expect_false(grepl("percentile", no_rank, fixed = TRUE))
})

test_that("a missing verdict is omitted rather than rendered empty", {
  html <- share_page(share_fixture(label = ""), TOKEN)
  expect_false(grepl('class="verdict"', html, fixed = TRUE))
  # The alt text falls back to the document title so the image is described.
  expect_match(html, 'alt="NYC Taxi Decision Simulator - Day #aZ3kQ9"', fixed = TRUE)
})

test_that("the SHARE_BASE_URL override reaches every absolute URL", {
  old <- Sys.getenv("SHARE_BASE_URL", unset = NA)
  on.exit(if (is.na(old)) Sys.unsetenv("SHARE_BASE_URL")
          else Sys.setenv(SHARE_BASE_URL = old))
  Sys.setenv(SHARE_BASE_URL = "http://localhost:8020/")
  html <- share_page(share_fixture(), TOKEN)
  expect_match(html, "http://localhost:8020/share/aZ3kQ9mLp1Rt.png", fixed = TRUE)
  expect_match(html, "http://localhost:8020/?ref=share", fixed = TRUE)
  # A trailing slash must not double up.
  expect_false(grepl("8020//share", html, fixed = TRUE))
})

test_that("API strings are escaped before they reach the page", {
  html <- share_page(share_fixture(label = "<script>alert(1)</script>"), TOKEN)
  expect_false(grepl("<script>alert", html, fixed = TRUE))
  expect_match(html, "&lt;script&gt;")
  # ...including the ones that land inside an attribute.
  html2 <- share_page(share_fixture(share_text = 'a "quote" & <b>'), TOKEN)
  expect_match(html2, "a &quot;quote&quot; &amp; &lt;b&gt;")
})

test_that("share_copy builds every line the page shows", {
  cpy <- share_copy(share_fixture(user_percentile = 73))
  expect_equal(cpy$day, "Day #aZ3kQ9")
  expect_equal(cpy$verdict, "I beat the Model!")
  expect_equal(cpy$title, "NYC Taxi Decision Simulator - Day #aZ3kQ9")
  expect_equal(cpy$description, "I beat the model today. \U0001F695\U0001F4CA")
  expect_equal(cpy$play, "Play your own day")
  expect_match(cpy$context, "drove 7 trips")
  expect_match(cpy$context, "\\$27\\.40/h")
  expect_match(cpy$ranking, "73rd percentile")
  expect_true(nzchar(cpy$footer))
})

test_that("ordinal() handles the irregular endings", {
  expect_equal(ordinal(1), "1st")
  expect_equal(ordinal(2), "2nd")
  expect_equal(ordinal(3), "3rd")
  expect_equal(ordinal(4), "4th")
  expect_equal(ordinal(11), "11th")
  expect_equal(ordinal(12), "12th")
  expect_equal(ordinal(13), "13th")
  expect_equal(ordinal(21), "21st")
  expect_equal(ordinal(113), "113th")
  expect_equal(ordinal(73.5), "74th")   # rounds, then applies the suffix
  expect_equal(ordinal(NA), "")
})
