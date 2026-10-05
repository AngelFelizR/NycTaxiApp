#!/bin/bash
# End-to-end exercise of the phase-3 experiment endpoints against a live API
# (the companion of api/dev/smoke.sh, which covers the phase-1/2 endpoints).
#
# POST /experiments is async: it answers 201 with status "setup" while the
# policy and baseline trajectories are computed in the background, so the
# script polls /state until the day starts before playing it.
#
# Run it from inside the dev container, where the repo is mounted at its
# root (both this script and .env live there):
#   bash api/dev/e2e_experiments.sh [client-ip]
#
# The client IP is part of the rate limit (3 experiments/day/IP), so pass a
# fresh one when re-running. The last steps also assume that
# MODELS_DIR/ReferenceDistribution.qs2 is installed (finish answers 503
# without it) and that SMTP_URL is empty (share-email answers 503 with it).
set -u

cd "$(dirname "$0")/../.."
line=$(grep -m1 "^API_INTERNAL_KEY=" .env); KEY=${line#API_INTERNAL_KEY=}
B=${TAXI_API_URL:-http://127.0.0.1:8000}
IP=${1:-198.51.100.90}
H=(-H "X-Internal-Key: $KEY" -H "X-Client-IP: $IP" -H "Content-Type: application/json")

fails=0
py() { python3 -c "import sys,json;d=json.load(sys.stdin);$1"; }
say() { echo; echo "== $1 =="; }
check() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then
    echo "  ok:   $3 = $2"
  else
    echo "  FAIL: $3 = $2 (expected $1)"
    fails=$((fails + 1))
  fi
}

say "1. POST /experiments (async create)"
out=$(curl -s -w '\n%{http_code} %{time_total}' -X POST "$B/experiments" "${H[@]}" \
  -d '{"company":"Uber","start_datetime":"2024-05-13T08:30:00Z","start_location_id":61}')
meta=$(echo "$out" | tail -1)
body=$(echo "$out" | head -1)
code=$(echo "$meta" | cut -d' ' -f1)
t=$(echo "$meta" | cut -d' ' -f2)
id=$(echo "$body" | py 'print(d["experiment_id"])')
rc=$(echo "$body" | py 'print(d["resume_code"])')
tok=$(echo "$body" | py 'print(d["share_token"])')
st=$(echo "$body" | py 'print(d["status"])')
mp=$(echo "$body" | py 'print(d.get("model_progress","MISSING"))')
nt=$(echo "$body" | py 'print("null" if d["next_trip"] is None else "trip")')
n=$(echo "$body" | grep -o '"experiment_id"' | wc -l)
echo "  id=$id status=$st model_progress=$mp next_trip=$nt in ${t}s"
check 201 "$code" "create"
check setup "$st" "create status"
check 0 "$mp" "create model_progress"
check null "$nt" "create next_trip"
check 1 "$n" "experiment_id occurrences in the body"

say "2. GET /experiments/{id} without X-Resume-Code"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' "$B/experiments/$id" "${H[@]}")
head -c 200 /tmp/e2e_r; echo
check 403 "$code" "get without resume code"

say "3. POST /finish while the day is still in setup"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/experiments/$id/finish" \
  "${H[@]}" -H "X-Resume-Code: $rc" -d '{}')
head -c 200 /tmp/e2e_r; echo
check 409 "$code" "finish during setup"

say "4. GET /state until the day starts"
status="$st"
tries=0
t0=$(date +%s.%N)
state=""
while [ "$status" != "in_progress" ] && [ "$status" != "finished" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 90 ]; then
    echo "  TIMEOUT waiting for in_progress"
    fails=$((fails + 1))
    break
  fi
  code=$(curl -s -o /tmp/e2e_s -w '%{http_code}' "$B/experiments/$id/state" \
    "${H[@]}" -H "X-Resume-Code: $rc")
  if [ "$code" != "200" ]; then
    echo "  state failed: $code $(cat /tmp/e2e_s)"
    fails=$((fails + 1))
    break
  fi
  state=$(cat /tmp/e2e_s)
  mp=$(echo "$state" | py 'print(d.get("model_progress","-"))')
  status=$(echo "$state" | py 'print(d["status"])')
  echo "  status=$status model_progress=$mp"
  sleep 1
done
t1=$(date +%s.%N)
echo "  ready in $(python3 -c "print(round($t1-$t0,1))")s status=$status"
check in_progress "$status" "state after the setup"

say "5. POST /decisions until the day is over"
steps=0
body="$state"
t0=$(date +%s.%N)
while [ "$status" != "finished" ] && [ "$steps" -lt 300 ]; do
  trip=$(echo "$body" | py 'nt=d.get("next_trip");print(nt["trip_id"] if nt else "")' 2>/dev/null)
  if [ -z "$trip" ]; then
    echo "  no next trip at step $steps (status=$status)"
    break
  fi
  out=$(curl -s -w '\n%{http_code}' -X POST "$B/experiments/$id/decisions" \
    "${H[@]}" -H "X-Resume-Code: $rc" -d "{\"trip_id\":$trip,\"accepted\":true}")
  body=$(echo "$out" | head -1)
  code=$(echo "$out" | tail -1)
  if [ "$code" != "200" ]; then
    echo "  decision failed at step $steps: $code $(echo "$body" | head -c 200)"
    fails=$((fails + 1))
    break
  fi
  status=$(echo "$body" | py 'print(d.get("status",""))' 2>/dev/null || echo parse-error)
  steps=$((steps + 1))
done
t1=$(date +%s.%N)
echo "  steps=$steps status=$status elapsed=$(python3 -c "print(round($t1-$t0,1))")s"

say "6. POST /decisions with a trip the player never saw"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/experiments/$id/decisions" \
  "${H[@]}" -H "X-Resume-Code: $rc" -d '{"trip_id":999999999,"accepted":true}')
head -c 200 /tmp/e2e_r; echo
check 409 "$code" "unknown trip_id"

say "7. GET /share-data/{token} (404 until the day is finished)"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code} %{time_total}' "$B/share-data/$tok" "${H[@]}")
head -c 200 /tmp/e2e_r; echo
check 404 "$(echo "$code" | cut -d' ' -f1)" "share-data before finish"

say "8. POST /feedback"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/experiments/$id/feedback" \
  "${H[@]}" -H "X-Resume-Code: $rc" -d '{"rating":5,"comment":"great","public":true}')
head -c 200 /tmp/e2e_r; echo
check 200 "$code" "feedback"

say "9. POST /share-email before finish (422, SMTP_URL is empty anyway)"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/experiments/$id/share-email" \
  "${H[@]}" -H "X-Resume-Code: $rc" -d '{"email":"driver@example.com"}')
head -c 200 /tmp/e2e_r; echo
check 422 "$code" "share-email before finish"

say "10. POST /finish (needs MODELS_DIR/ReferenceDistribution.qs2)"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/experiments/$id/finish" \
  "${H[@]}" -H "X-Resume-Code: $rc" -d '{}')
head -c 400 /tmp/e2e_r; echo
check 200 "$code" "finish"
pct=$(cat /tmp/e2e_r | py 'print(d["result"]["user_percentile"])' 2>/dev/null || echo MISSING)
check_ok=$(python3 -c "import sys;p='$pct';sys.exit(0 if p not in ('MISSING','None') else 1)") \
  && echo "  ok:   user_percentile = $pct" \
  || { echo "  FAIL: user_percentile = $pct"; fails=$((fails + 1)); }

say "11. POST /abandon after finish"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/experiments/$id/abandon" \
  "${H[@]}" -H "X-Resume-Code: $rc" -d '{}')
head -c 200 /tmp/e2e_r; echo
check 409 "$code" "abandon after finish"

say "12. POST /waitlist"
# waitlist.email is UNIQUE, so a repeated run needs a fresh address.
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' -X POST "$B/waitlist" "${H[@]}" \
  -d "{\"email\":\"e2e-$(date +%s)@example.com\"}")
head -c 200 /tmp/e2e_r; echo
check 200 "$code" "waitlist"

say "13. GET /metrics"
code=$(curl -s -o /tmp/e2e_r -w '%{http_code}' "$B/metrics" "${H[@]}")
head -c 300 /tmp/e2e_r; echo
check 200 "$code" "metrics"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL OK (client-ip $IP)"
else
  echo "$fails check(s) FAILED (client-ip $IP)"
  exit 1
fi
