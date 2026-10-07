#!/usr/bin/env bash
# Availability alert for the private services (master doc 11: "alertas
# minimas" -- no Prometheus, no dashboard).
#
#   0 * * * * /srv/nyctaxi/nyctaxi/infra/scripts/health_check.sh
#
# Why this exists at all: the external monitor of section 8.1 watches
# https://nyctaxiapp.angelfeliz.com/, which is ShinyProxy's landing page -- and
# that page does not depend on the API. If Postgres dies, or the models fail
# to load, the public monitor stays green and the first visitor to press
# "Validate" is the one who finds out. This script probes the four things that
# actually make the product work, from inside the host's Docker context, and
# mails when one is down.
#
# It runs on the host (it needs `docker exec`); the dev container has no
# Docker and this alert is a production concern.
set -euo pipefail

API_C="${HEALTH_API_C:-nyctaxi-api}"
SHARE_C="${HEALTH_SHARE_C:-nyctaxi-share}"
PG_C="${HEALTH_PG_C:-nyctaxi-postgres}"
REDIS_C="${HEALTH_REDIS_C:-nyctaxi-redis}"

LOG="${HEALTH_LOG:-/var/log/nyctaxi-health.log}"
# Re-alert at most this often: a service that is down for an hour should not
# produce 60 mails.
COOLDOWN_S="${HEALTH_ALERT_COOLDOWN:-21600}"   # 6 h
STAMP="${XDG_STATE_HOME:-/var/tmp}/nyctaxi-health-alert"

API_KEY="$(grep -m1 '^API_INTERNAL_KEY=' "$(dirname "${BASH_SOURCE[0]}")/../../.env" 2>/dev/null \
           | cut -d= -f2- || true)"

# The default lives under /var/log because cron on the VM runs as root; on a
# workstation it is not writable. Failures must still reach stderr rather than
# kill the script under `set -e`.
logit() {
  { echo "$1" >>"$LOG"; } 2>/dev/null || echo "$1" >&2
}

problems=()
note_problem() { problems+=("$1"); }
# One line per problem reads better than space-joined prose.
SUMMARY() {
  local out="" p
  for p in "${problems[@]}"; do out+="${out:+; }${p}"; done
  echo "$out"
}

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# ---- the four things the product cannot work without ----------------------
if ! running "$API_C"; then
  note_problem "$API_C is not running"
else
  code="$(docker exec "$API_C" curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
            -H "X-Internal-Key: $API_KEY" http://127.0.0.1:8000/health || echo 000)"
  [[ "$code" == "200" ]] || note_problem "$API_C /health -> ${code} (503 means the database or a model is missing)"
fi

if ! running "$SHARE_C"; then
  note_problem "$SHARE_C is not running"
else
  code="$(docker exec "$SHARE_C" curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
            http://127.0.0.1:8001/health || echo 000)"
  [[ "$code" == "200" ]] || note_problem "$SHARE_C /health -> $code"
fi

if ! running "$PG_C"; then
  note_problem "$PG_C is not running"
elif ! docker exec "$PG_C" pg_isready -U "${POSTGRES_USER:-nyctaxi}" >/dev/null 2>&1; then
  note_problem "$PG_C is not accepting connections"
fi

if ! running "$REDIS_C"; then
  note_problem "$REDIS_C is not running"
elif ! docker exec "$REDIS_C" redis-cli ping >/dev/null 2>&1; then
  note_problem "$REDIS_C does not answer PING"
fi

# ---- outcome ---------------------------------------------------------------
LINE="$(date -Is)"
if (( ${#problems[@]} == 0 )); then
  logit "$LINE ok"
  # A green run clears the cooldown so the next incident alerts immediately.
  rm -f "$STAMP"
  exit 0
fi

MSG="$(printf '%s\n' "${problems[@]}")"
logit "$LINE FAIL: $(SUMMARY)"

if [[ -f "$STAMP" ]] && (( $(date +%s) - $(stat -c %Y "$STAMP") < COOLDOWN_S )); then
  logit "$LINE (alert suppressed, inside cooldown)"
  exit 1
fi

: "${SMTP_URL:?Set SMTP_URL to alert on a dead service}"
: "${HEALTH_ALERT_TO:?Set HEALTH_ALERT_TO (recipient address)}"
FROM="${HEALTH_ALERT_FROM:-alerts@nyctaxiapp.angelfeliz.com}"

BODY="$(cat <<EOF
Service alert on nyctaxiapp.angelfeliz.com

${LINE}

${MSG}

Because the public monitor (section 8.1) watches the landing page, which does
not depend on these, it will still be green right now.

Runbook: docs/operations/runbook.md
EOF
)"

# curl prepends -H headers to the upload WITHOUT a blank line, so the body
# looks like a continuation of the Subject header and the server answers
# "malformed header line" (451). The whole RFC822 message -- headers, empty
# line, body -- goes in the upload instead.
MSG="$(printf 'From: %s\nTo: %s\nSubject: [nyctaxi] service down: %s\nContent-Type: text/plain; charset=utf-8\n\n%s' \
       "$FROM" "$HEALTH_ALERT_TO" "$(SUMMARY)" "$BODY")"
if curl --silent --show-error --fail --max-time 30 \
     --url "$SMTP_URL" \
     --mail-from "$FROM" \
     --mail-rcpt "$HEALTH_ALERT_TO" \
     --upload-file - <<<"$MSG"; then
  touch "$STAMP"
  logit "$LINE (alert sent)"
else
  logit "$LINE (mail FAILED)"
fi

exit 1
