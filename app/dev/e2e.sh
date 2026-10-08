#!/usr/bin/env bash
# Start what Cypress needs, run it, tear it down.
#
#   ./dev/e2e.sh                      # app + real API + proxy, all specs
#   ./dev/e2e.sh --spec 'cypress/e2e/setup-screen.cy.js'
#
# Run from a nix-shell that has the app's dependencies (nix-shell
# app/default.dev.nix): Cypress itself is baked into the development image
# (Dockerfile layer 11), R and the packages come from the shell.
#
# The app is R, so Cypress cannot start it the way it starts a node dev
# server -- that is what e2e.devServer in cypress.config.cjs is not for. This
# script owns every process and its lifetime: the API (and share/, which
# /share-email needs) when nothing is answering already, the proxy that puts
# the client IP on the wire, and the app itself.
#
# There is no mock (ADR-0014). The UI is tested against the service that runs
# in production, with its database, its limiter and its models -- and the one
# status section 10 asks about that the network can really produce, 429, is
# provoked for real in rate-limit.cy.js instead of being dictated to a stub.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(cd ../.. && pwd)"
APP_PORT="${APP_PORT:-3838}"
PROXY_PORT="${PROXY_PORT:-3839}"
API_PORT="${API_PORT:-8000}"

export APP_PORT
export CYPRESS_BASE_URL="http://127.0.0.1:${PROXY_PORT}"
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
share_pid=""
proxy_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  [ -n "$proxy_pid" ] && kill "$proxy_pid" 2>/dev/null || true
  [ -n "$api_pid" ] && kill "$api_pid" 2>/dev/null || true
  [ -n "$share_pid" ] && kill "$share_pid" 2>/dev/null || true
}
trap cleanup EXIT

log_dir="$(mktemp -d)"
echo "logs: $log_dir"

# The database and Redis live in the root compose. Outside it -- where this
# script runs, on the host or in CI's container -- the names .env carries
# ("postgres", "redis") resolve nowhere, while the compose publishes both on
# the loopback. getent decides which of the two worlds we are in instead of
# guessing from the hostname.
env_from_dotenv() {
  local key=$1 value
  [ -n "${!key:-}" ] && return 0
  [ -f "$ROOT/.env" ] || return 0
  value=$(grep -m1 "^${key}=" "$ROOT/.env" | cut -d= -f2-) || true
  [ -n "$value" ] && export "$key=$value"
}
resolvable_or() {
  if [ -n "$1" ] && getent hosts "$1" >/dev/null 2>&1; then
    printf '%s' "$1"
  else
    printf '%s' "$2"
  fi
}
api_up() {
  curl -sf --max-time 2 -o /dev/null \
    -H "X-Internal-Key: ${API_INTERNAL_KEY:-}" \
    "${TAXI_API_URL}/health" 2>/dev/null
}
share_up() {
  curl -sf --max-time 2 -o /dev/null \
    "http://127.0.0.1:${SHARE_PORT:-8020}/health" 2>/dev/null
}

start_api() {
  local key
  for key in POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
             REDIS_PORT API_INTERNAL_KEY IP_HASH_SALT; do
    env_from_dotenv "$key"
  done
  POSTGRES_HOST="$(resolvable_or "${POSTGRES_HOST:-postgres}" 127.0.0.1)"
  export POSTGRES_HOST
  REDIS_HOST="$(resolvable_or "${REDIS_HOST:-redis}" 127.0.0.1)"
  export REDIS_HOST

  # Deliberately NOT read from .env: those two describe the compose network
  # (http://share:8001, smtp://mailpit:1025) and this script runs outside it.
  # The mail catcher is the one the compose brings up, on the loopback it
  # publishes; SMTP_STARTTLS=0 because a local relay has no certificate and
  # .env.example says as much.
  export SHARE_URL="${SHARE_URL:-http://127.0.0.1:8020}"
  export SMTP_URL="${SMTP_URL:-smtp://127.0.0.1:1025}"
  export SMTP_STARTTLS="${SMTP_STARTTLS:-0}"

  if ! api_up; then
    echo "starting the API on :${API_PORT}"
    (cd "$ROOT" && exec nix-shell api/default.dev.nix --run \
      "Rscript api/plumber.R") >"$log_dir/api.log" 2>&1 &
    api_pid=$!
    for _ in $(seq 1 90); do
      api_up && break
      kill -0 "$api_pid" 2>/dev/null || break
      sleep 1
    done
    api_up || {
      echo "the API never answered on $TAXI_API_URL" >&2
      tail -40 "$log_dir/api.log" >&2 || true
      exit 1
    }
    echo "API is up"
  else
    echo "API already answering on $TAXI_API_URL"
  fi

  # /share-email pulls the card from share/ and answers 503 without it (5.6),
  # so the email prompt in Results is not testable until this is running.
  if ! share_up; then
    echo "starting share/ on :${SHARE_PORT:-8020}"
    (cd "$ROOT" && exec nix-shell share/default.dev.nix --run \
      "Rscript share/plumber.R") >"$log_dir/share.log" 2>&1 &
    share_pid=$!
    for _ in $(seq 1 60); do
      share_up && break
      kill -0 "$share_pid" 2>/dev/null || break
      sleep 1
    done
    share_up || {
      echo "share/ never answered on :${SHARE_PORT:-8020}" >&2
      tail -40 "$log_dir/share.log" >&2 || true
      exit 1
    }
    echo "share/ is up"
  fi
}

start_api

# The proxy is what puts X-Client-IP on the wire. Shiny reads it off the
# WebSocket handshake, which a page cannot set headers on, so without it every
# session is seen as 127.0.0.1 and the IP test would compare the socket
# address against itself. dev/e2e-proxy.js explains the rest.
PROXY_PORT="$PROXY_PORT" PROXY_UPSTREAM_PORT="$APP_PORT" \
  node dev/e2e-proxy.js >"$log_dir/proxy.log" 2>&1 &
proxy_pid=$!
echo "proxy on :$PROXY_PORT -> :$APP_PORT (pid $proxy_pid)"

Rscript -e 'shiny::runApp(".", host = "127.0.0.1",
                           port = as.integer(Sys.getenv("APP_PORT")))' \
  >"$log_dir/app.log" 2>&1 &
app_pid=$!
echo "app on :$APP_PORT (pid $app_pid)"

# Wait for the app, and say why it did not come up rather than timing out
# silently: the first thing a missing data volume looks like is a hang. The
# URL is the proxy's, so this also proves the proxy forwards.
up=0
for _ in $(seq 1 120); do
  if curl -sf --max-time 2 "$CYPRESS_BASE_URL/" > /dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
  if ! kill -0 "$proxy_pid" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ "$up" != "1" ]; then
  echo "the app never answered on $CYPRESS_BASE_URL" >&2
  echo "--- app log ---" >&2
  tail -40 "$log_dir/app.log" >&2 || true
  echo "--- proxy log ---" >&2
  tail -20 "$log_dir/proxy.log" >&2 || true
  exit 1
fi
echo "app is up (through the proxy)"

echo "DIAG PATH=$PATH"
echo "DIAG cypress=$(command -v cypress || echo NO) node=$(command -v node || echo NO)"
/opt/npm/bin/cypress run "$@"
