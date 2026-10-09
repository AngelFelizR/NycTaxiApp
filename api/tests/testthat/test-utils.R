test_that("validation predicates follow the contract", {
  expect_true(is_string("x"))
  expect_false(is_string(c("a", "b")))
  expect_false(is_string(NA_character_))
  expect_true(is_number(1.5))
  expect_false(is_number(Inf))
  expect_false(is_number(NA_real_))
  expect_true(is_wholenumber(3))
  expect_false(is_wholenumber(3.5))
  expect_true(is_zone_id(1))
  expect_true(is_zone_id(265))
  expect_false(is_zone_id(0))
  expect_false(is_zone_id(266))
  expect_false(is_zone_id(1.5))
  expect_true(valid_company("Uber"))
  expect_true(valid_company("Lyft"))
  expect_false(valid_company("Via"))
  expect_identical(company_to_hvfhs("Uber"), "HV0003")
  expect_identical(company_to_hvfhs("Lyft"), "HV0005")
})

test_that("missing_fields reports absent keys only", {
  payload <- list(a = 1, c = 3)
  expect_identical(missing_fields(payload, c("a", "b", "c")), c("b"))
  expect_identical(missing_fields(payload, c("a")), character(0))
})

test_that("api_error sets the contract Error shape and breaks", {
  response <- fake_response()
  res <- api_error(response, 422L, "unprocessable_entity", "bad value")
  expect_s3_class(res, "plumber_control")
  expect_identical(response$status, 422L)
  expect_identical(
    response$body,
    list(error = "unprocessable_entity", message = "bad value")
  )
})

test_that("read_json_body enforces content type and valid JSON", {
  request <- fake_request(list("content-type" = "application/json"))

  res <- read_json_body(NULL, request)
  expect_true(is_api_fail(res))
  expect_identical(res$status, 400L)
  expect_identical(res$message, "Request body is required.")

  res <- read_json_body(json_raw('{"a": 1}'),
    fake_request(list("content-type" = "text/plain")))
  expect_true(is_api_fail(res))
  expect_identical(res$message, "Content-Type must be application/json.")

  res <- read_json_body(charToRaw("{broken"), request)
  expect_true(is_api_fail(res))
  expect_identical(res$message, "The request payload is invalid.")

  res <- read_json_body(charToRaw("[1, 2]"), request)
  expect_true(is_api_fail(res))

  ok <- read_json_body(json_raw(list(a = 1)), request)
  expect_false(is_api_fail(ok))
  expect_identical(ok$a, 1L)
})

test_that("load_dotenv only fills variables that are not set", {
  path <- tempfile(fileext = ".env")
  writeLines(c("FOO_FROM_ENV=bar", "# comment", "EMPTY_LIKE=x",
               "EMPTY_BLANK="), path)
  on.exit(unlink(path), add = TRUE)
  old <- Sys.getenv("FOO_FROM_ENV", unset = NA_character_)
  on.exit(
    if (is.na(old)) Sys.unsetenv("FOO_FROM_ENV") else Sys.setenv(FOO_FROM_ENV = old),
    add = TRUE
  )
  Sys.setenv(FOO_FROM_ENV = "already")
  expect_true(load_dotenv(path))
  expect_identical(Sys.getenv("FOO_FROM_ENV"), "already")
  expect_identical(Sys.getenv("EMPTY_LIKE"), "x")
  # A blank value must stay UNSET, not become "set to empty": R answers ""
  # (not the default) for a set-but-empty variable, so loading `VAR=` would
  # defeat every Sys.getenv(VAR, "default") -- on a fresh .env.example copy
  # that turned API_PORT into NA and TAXI_MODELS_DIR into "/...".
  expect_identical(Sys.getenv("EMPTY_BLANK", unset = NA_character_),
                   NA_character_,
                   label = "a blank .env line leaves the variable unset")
})

test_that("every blank line in the real .env.example stays unset after load", {
  # The fresh-clone regression, against the actual file the README tells you
  # to copy: loading it must not shadow a single default. This is the test
  # that would have caught API_PORT=/TAXI_MODELS_DIR= on day one.
  example <- file.path(model_state$repo_root, ".env.example")
  skip_if_not(file.exists(example), ".env.example not reachable from here")
  lines <- trimws(readLines(example, warn = FALSE))
  declared <- sub("=.*$", "", grep("^[A-Z0-9_]+=", lines, value = TRUE))
  blanks <- sub("=.*$", "", grep("^[A-Z0-9_]+=$", lines, value = TRUE))
  expect_gt(length(blanks), 5)
  # load_dotenv writes to the process env: save everything the file can touch
  # (blanks and non-blanks alike) so no later test inherits http://api:8000.
  saved <- setNames(lapply(declared, function(k) Sys.getenv(k, unset = NA_character_)),
                    declared)
  on.exit(for (k in declared) {
    if (is.na(saved[[k]])) Sys.unsetenv(k)
    else do.call(Sys.setenv, setNames(list(saved[[k]]), k))
  }, add = TRUE)
  for (k in declared) Sys.unsetenv(k)
  load_dotenv(example)
  still_unset <- vapply(blanks, function(k) is.na(Sys.getenv(k, unset = NA_character_)),
                        logical(1))
  expect_true(all(still_unset),
              label = paste("blank lines load_dotenv set:",
                            paste(blanks[!still_unset], collapse = ", ")))
})

test_that("iso_utc and week_day_names match the contract examples", {
  expect_identical(
    iso_utc(as.POSIXct("2025-01-07 15:00:00", tz = "UTC")),
    "2025-01-07T15:00:00Z"
  )
  expect_identical(week_day_names()[1], "sunday")
  expect_identical(week_day_names()[2], "monday")
})

test_that("internal_auth_header accepts only the exact key", {
  old <- Sys.getenv("API_INTERNAL_KEY", unset = NA_character_)
  on.exit(
    if (is.na(old)) Sys.unsetenv("API_INTERNAL_KEY") else
      Sys.setenv(API_INTERNAL_KEY = old),
    add = TRUE
  )
  Sys.setenv(API_INTERNAL_KEY = "s3cr3t-key")

  response <- fake_response()
  res <- internal_auth_header(
    fake_request(list("x-internal-key" = "s3cr3t-key")), response
  )
  expect_identical(res, plumber2::Next)

  response <- fake_response()
  res <- internal_auth_header(fake_request(), response)
  expect_s3_class(res, "plumber_control")
  expect_identical(response$status, 403L)
  expect_identical(response$body$error, "forbidden")

  response <- fake_response()
  res <- internal_auth_header(
    fake_request(list("x-internal-key" = "wrong")), response
  )
  expect_identical(response$status, 403L)
})
