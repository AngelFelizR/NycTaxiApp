# Start the mock API on http://127.0.0.1:8000 (run from the project root)
plumber2::api("dev/mock_api.R") |>
  plumber2::api_run(port = 8000)
