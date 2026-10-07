#!/usr/bin/env bash
# End-to-end smoke test: bring up the PRODUCTION stack on a workstation and
# verify the things parsers cannot (master doc §10 "exposición de red", §8.6's
# post-deploy smoke test).
#
#   ./infra/scripts/smoke-stack.sh            # up, verify, down
#   SMOKE_KEEP=1 ./infra/scripts/smoke-stack.sh   # leave it running
#
# Uses docker-compose.prod.yml + docker-compose.smoke.yml: the overlay only
# re-points /models and /data at the directories .env already has and swaps
# /etc/letsencrypt for self-signed certificates, so nothing outside this
# repository is touched.
#
# What this does NOT prove: it never opens a Shiny session, so the app inside
# a ShinyProxy container and its data mount are not exercised. That needs a
# browser and belongs to the load test (phase 8).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

COMPOSE=(docker compose -f docker-compose.prod.yml -f docker-compose.smoke.yml)
SMOKE_CERTS="${SMOKE_CERTS:-/tmp/nyctaxi-certs}"
SMOKE_KEEP="${SMOKE_KEEP:-0}"
# -k: the certificate is self-signed and only exists for this run.
BASE="https://127.0.0.1"
CURL=(curl -sk --max-time 20)
WAIT_S="${SMOKE_WAIT:-300}"

FAILED=0
note() { printf '  %-58s %s\n' "$1" "$2"; }
fail() { note "$1" "FAIL  ($2)"; FAILED=$((FAILED + 1)); }
pass() { note "$1" "ok"; }

on_exit() {
  if [[ "$SMOKE_KEEP" != "1" ]]; then
    echo; echo "tearing down..."
    "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
  else
    echo; echo "SMOKE_KEEP=1 -- stack left running."
  fi
}
trap on_exit EXIT

# ---------------------------------------------------------------- 0. inputs
for v in MODELS_DIR DATA_DIR; do
  val="$(grep -E "^${v}=" .env 2>/dev/null | cut -d= -f2- || true)"
  if [[ -z "$val" || ! -d "$val" ]]; then
    echo "FAIL: ${v} is unset or missing in .env (got: '${val}')" >&2
    exit 1
  fi
  export "$v=$val"
done
for f in AcceptRejectPolicyFitted.qs2 NycTrips2024_sample_week.parquet; do
  ls "$MODELS_DIR/$f" "$DATA_DIR/$f" >/dev/null 2>&1 || true
done
echo "models: $MODELS_DIR"
echo "data:   $DATA_DIR"

# --------------------------------------------------------------- 1. certs
# nginx refuses to start without them, and the production file mounts
# /etc/letsencrypt, which does not exist on a workstation.
CERT_DIR="$SMOKE_CERTS/live/nyctaxiapp.angelfeliz.com"
if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  echo "generating self-signed certificate in $SMOKE_CERTS ..."
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=nyctaxiapp.angelfeliz.com" \
    -addext "subjectAltName=DNS:nyctaxiapp.angelfeliz.com,DNS:localhost" \
    >/dev/null 2>&1
fi
export SMOKE_CERTS
# The images built on this machine are tagged :test; :latest only exists once
# CI has pushed. Nothing here starts a Shiny session, so the tag only matters
# for api and share -- the shiny image is used when a session starts (phase 8).
export NYCTAXI_TAG="${NYCTAXI_TAG:-test}"

# --------------------------------------------------------------- 2. up
echo
echo "starting the stack..."
if ! "${COMPOSE[@]}" up -d --remove-orphans; then
  echo "FAIL: compose could not start the stack" >&2
  exit 1
fi

echo "waiting up to ${WAIT_S}s for the api healthcheck (it needs Postgres and the models)..."
deadline=$(( $(date +%s) + WAIT_S ))
while true; do
  st="$(docker inspect -f '{{.State.Health.Status}}' nyctaxi-api 2>/dev/null || echo starting)"
  [[ "$st" == "healthy" ]] && break
  if (( $(date +%s) > deadline )); then
    docker logs nyctaxi-api 2>&1 | tail -30 >&2
    echo "FAIL: nyctaxi-api never became healthy (last status: $st)" >&2
    exit 1
  fi
  sleep 3
done
# share and nginx start after the api, and ShinyProxy is a JVM: it can take
# 30-60s before it accepts a connection. Wait for the edge to answer rather
# than guessing with a sleep -- a 502 here would be reported as a real failure.
echo "waiting for the edge (Nginx -> ShinyProxy)..."
edge_deadline=$(( $(date +%s) + 120 ))
while true; do
  code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)"
  [[ "$code" == "200" ]] && break
  if (( $(date +%s) > edge_deadline )); then
    echo "note: the edge still answers $code after 120s" >&2
    docker logs nyctaxi-shinyproxy 2>&1 | tail -20 >&2
    break
  fi
  sleep 3
done

echo
echo "checks:"

# ---- (a) section 10: no route to the API through the edge --------------
code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/api/health" || true)"
if [[ "$code" == "404" ]]; then pass "(a) GET /api/health -> 404"; else fail "(a) GET /api/health -> $code" "expected 404"; fi

# ---- (c) section 10: only nginx publishes a port ------------------------
# grep exits 1 with no match and `set -o pipefail` would abort the whole run
# instead of failing one check, so every probe below is guarded.
raw_ports="$(docker ps --filter 'label=com.docker.compose.project=nyctaxi' \
  --format '{{.Names}}={{.Ports}}' 2>/dev/null || true)"
# A published port is the only one rendered with "->": 0.0.0.0:80->80/tcp.
# `expose:` shows as "8001/tcp" with no arrow and must NOT count.
ports="$(grep -oE '[0-9]+->' <<<"$raw_ports" 2>/dev/null \
         | sed 's/->//' | sort -u | tr '\n' ' ' || true)"
if [[ -z "$ports" ]]; then
  fail "(c) published ports" "could not read docker ps: $raw_ports"
elif [[ "$ports" == "443 80 " ]]; then
  pass "(c) published ports = {80, 443}"
else
  fail "(c) published ports = {$ports}" "expected {80, 443}"
fi

# ---- the edge actually serves the app -----------------------------------
code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/" || true)"
if [[ "$code" == "200" ]]; then pass "GET / -> 200 (Nginx -> ShinyProxy)"; else fail "GET / -> $code" "expected 200"; fi

# ---- the public share service, through Nginx and the private network ----
ctype="$("${CURL[@]}" -o /dev/null -w '%{content_type}' "$BASE/share/000000000000" || true)"
code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/share/000000000000" || true)"
if [[ "$code" == "404" && "$ctype" == application/json* ]]; then
  pass "GET /share/<unknown> -> 404 application/json"
else
  fail "GET /share/<unknown> -> $code ($ctype)" "expected 404 + application/json"
fi

# ---- (e) share must not hold database credentials -----------------------
if docker exec nyctaxi-share env 2>/dev/null | grep -q '^POSTGRES_'; then
  fail "(e) share has POSTGRES_* in its environment" "section 1.0 forbids it"
else
  pass "(e) share has no POSTGRES_* variables"
fi

# ---- WebSocket, reported rather than asserted ---------------------------
# Nginx maps Upgrade/Connection (see nginx.conf), but proving it needs a live
# Shiny session: ShinyProxy's landing page answers 200 to an upgrade request
# and exposes no websocket route until a session starts, so a 200 here is
# expected and a 101 would mean nothing either. Verified when a session runs
# (phase 8); until then this only records what the edge answers today.
ws="$("${CURL[@]}" --http1.1 -o /dev/null -w '%{http_code}' \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "$BASE/" || true)"
note "WebSocket upgrade against / -> $ws (needs a session: phase 8)" "INFO"
if docker exec nyctaxi-nginx nginx -T 2>/dev/null | grep -q 'proxy_set_header Upgrade'; then
  pass "nginx is configured to forward Upgrade/Connection"
else
  fail "nginx has no proxy_set_header Upgrade" "Shiny would fall back to SockJS"
fi

# ---- (f) section 10: a Shiny instance cannot reach the database ---------
# The ephemeral Shiny containers join nyctaxi_api_net and nothing else (1.0),
# so from that network the API has to answer and Postgres and Redis must not
# resolve at all. Simulated with a throwaway container instead of starting a
# real session -- same network, same result, no browser.
if docker run --rm --network nyctaxi_api_net alpine:latest \
     sh -c 'nc -z -w 3 api 8000' >/dev/null 2>&1; then
  pass "(f) from api_net: api:8000 is reachable"
else
  fail "(f) from api_net: api:8000 unreachable" "the UI could not talk to the API"
fi

# postgres and redis exist only on nyctaxi_data_net, so DNS itself has to fail
# here -- not just the connection.
unreachable() {
  if docker run --rm --network nyctaxi_api_net alpine:latest \
       sh -c "nc -z -w 3 $1 $2" >/dev/null 2>&1; then
    fail "(f) from api_net: $1:$2 is reachable" "section 1.0 forbids it"
  else
    pass "(f) from api_net: $1:$2 is unreachable"
  fi
}
unreachable postgres 5432
unreachable redis 6379

# ---- (d) section 10: every endpoint answers 403 without the key ---------
# The middleware is unit-tested (api/tests/test-utils.R); this is the router
# actually applying it, with the key deliberately absent.
# req_perform() throws on 4xx unless is_error is off (same gotcha as
# share/R/api_client.R), so the status has to be read from a request that is
# allowed to fail.
nokey="$(docker exec nyctaxi-api Rscript -e '
  r <- httr2::request("http://127.0.0.1:8000/health")
  r <- httr2::req_timeout(r, 5)
  r <- httr2::req_error(r, is_error = ~ FALSE)
  cat(httr2::resp_status(httr2::req_perform(r)))' 2>/dev/null | tail -1 || true)"
if [[ "$nokey" == "403" ]]; then
  pass "(d) GET /health without X-Internal-Key -> 403"
else
  fail "(d) GET /health without X-Internal-Key -> ${nokey:-error}" "expected 403"
fi

# ---- §8.2: an upstream 503 falls into capacity-full.html ----------------
# Stopping the API makes share answer 503, which is exactly the path Nginx
# intercepts. The landing page itself does not depend on the API, so we probe
# through share.
echo "stopping the api to exercise error_page 503..."
docker stop nyctaxi-api >/dev/null
sleep 3
body="$("${CURL[@]}" "$BASE/share/000000000000" 2>/dev/null || true)"
if grep -qi "All the cabs are out" <<<"$body" 2>/dev/null; then
  pass "upstream 503 -> capacity-full.html"
else
  fail "upstream 503 -> $(head -c 60 <<<"$body")" "expected capacity-full.html"
fi
docker start nyctaxi-api >/dev/null

# ---------------------------------------------------------------- summary
echo
if (( FAILED > 0 )); then
  echo "SMOKE FAILED: $FAILED check(s)"
  echo "containers:"
  "${COMPOSE[@]}" ps || true
  exit 1
fi
echo "SMOKE PASSED"
