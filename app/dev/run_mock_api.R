# Start the mock API on http://127.0.0.1:8010 (run from app/, cwd = app/).
# Development only: the real API is api/plumber.R.
source("dev/mock_api.R")
plumber2::api_run(mock_api(port = 8010L), block = TRUE, silent = TRUE)
