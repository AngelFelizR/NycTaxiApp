#!/usr/bin/env bash
# Start what Cypress needs, run it, tear it down.
#
#   ./dev/e2e.sh                      # app + mock API, all specs
#   ./dev/e2e.sh --spec 'cypress/e2e/setup-screen.cy.js'
#
# Run from a nix-shell that has the app's dependencies (nix-shell
# app/default.dev.nix): Cypress itself is baked into the development image
# (Dockerfile layer 11), R and the packages come from the shell.
#
# The app is R, so Cypress cannot start it the way it starts a node dev
# server -- that is what e2e.devServer in cypress.config.cjs is not for. This
# script owns both processes and their lifetime.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PORT="${APP_PORT:-3838}"
API_PORT="${API_PORT:-8010}"
export APP_PORT
export CYPRESS_BASE_URL="http://127.0.0.1:${APP_PORT}"
# The app reads this before .env, so the mock wins over whatever the repo's
# .env says (load_env_file never overrides a variable that is already set).
export TAXI_API_URL="http://127.0.0.1:${API_PORT}"
export API_INTERNAL_KEY="${API_INTERNAL_KEY:-cypress-e2e-internal-key}"
export ENV="${ENV:-development}"
# The image sets this (Dockerfile layer 11), but an SSH session does not carry
# the container's environment and nix-shell cannot invent it: without it the
# binary download goes looking in ~/.cache and reports "No version of Cypress
# is installed".
export CYPRESS_CACHE_FOLDER="${CYPRESS_CACHE_FOLDER:-/opt/cypress-cache}"

# nix-shell rewrites PATH from its buildInputs. Cypress and node come from the
# image's own ENV (Dockerfile layer 11), so prepend them unconditionally --
# prepending twice is harmless, and a conditional check that runs before the
# shell has settled is how the first version called a binary that was there.
PATH="/opt/npm/bin:/nix/profiles/node/bin:${PATH}"
export PATH

app_pid=""
api_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "$api_pid" ] && kill "$api_pid" 2>/dev/null || true
}
trap cleanup EXIT

log_dir="$(mktemp -d)"
echo "logs: $log_dir"

if [ "${WITH_MOCK_API:-1}" = "1" ]; then
  Rscript dev/run_mock_api.R > "$log_dir/api.log" 2>&1 &
  api_pid=$!
  echo "mock API on :$API_PORT (pid $api_pid)"
fi

Rscript -e 'shiny::runApp(".", host = "127.0.0.1",
                           port = as.integer(Sys.getenv("APP_PORT")))' \
  > "$log_dir/app.log" 2>&1 &
app_pid=$!
echo "app on :$APP_PORT (pid $app_pid)"

# Wait for the app, and say why it did not come up rather than timing out
# silently: the first thing a missing data volume looks like is a hang.
up=0
for _ in $(seq 1 120); do
  if curl -sf --max-time 2 "$CYPRESS_BASE_URL/" > /dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ "$up" != "1" ]; then
  echo "the app never answered on $CYPRESS_BASE_URL" >&2
  echo "--- app log ---" >&2
  tail -40 "$log_dir/app.log" >&2 || true
  exit 1
fi
echo "app is up"

echo "DIAG PATH=$PATH"
echo "DIAG cypress=$(command -v cypress || echo NO) node=$(command -v node || echo NO)"
/opt/npm/bin/cypress run "$@"
