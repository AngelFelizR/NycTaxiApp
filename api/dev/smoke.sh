#!/bin/bash
# HTTP smoke test for the phase-1 endpoints. Expects the API running on
# 127.0.0.1:8000 and the repo .env (API_INTERNAL_KEY). Works from anywhere.
cd "$(dirname "$0")/../.." || exit 1
line=$(grep -m1 "^API_INTERNAL_KEY=" .env); KEY=${line#API_INTERNAL_KEY=}
B=http://127.0.0.1:8000
show() { echo "HTTP $1 | $2"; }
echo "== 1. health without key =="
show "$(curl -s -o /tmp/r1 -w '%{http_code}' $B/health)" "$(cat /tmp/r1)"
echo "== 2. health with key =="
show "$(curl -s -o /tmp/r2 -w '%{http_code}' -H "X-Internal-Key: $KEY" $B/health)" "$(cat /tmp/r2)"
echo "== 3. predict without key =="
show "$(curl -s -o /tmp/r3 -w '%{http_code}' -X POST $B/predict -H 'Content-Type: application/json' -d '{}')" "$(cat /tmp/r3)"
echo "== 4. predict bad key =="
show "$(curl -s -o /tmp/r4 -w '%{http_code}' -X POST $B/predict -H 'X-Internal-Key: mala' -H 'Content-Type: application/json' -d '{}')" "$(cat /tmp/r4)"
echo "== 5. predict valid payload =="
PAYLOAD='{"pulocation_id":61,"dolocation_id":230,"trip_miles":2.5,"trip_time_sec":1500,"driver_pay":28.5,"request_datetime":"2025-01-06T08:30:00Z","tips":5.0,"company":"Uber","trip_id":12345}'
show "$(curl -s -o /tmp/r5 -w '%{http_code} t=%{time_total}s' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d "$PAYLOAD")" "$(cat /tmp/r5)"
echo "== 6. predict missing field =="
show "$(curl -s -o /tmp/r6 -w '%{http_code}' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"pulocation_id":61}')" "$(cat /tmp/r6)"
echo "== 7. predict zone out of range =="
show "$(curl -s -o /tmp/r7 -w '%{http_code}' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"pulocation_id":999,"dolocation_id":230,"trip_miles":2.5,"trip_time_sec":1500,"driver_pay":28.5,"request_datetime":"2025-01-06T08:30:00Z"}')" "$(cat /tmp/r7)"
echo "== 8. predict broken JSON =="
show "$(curl -s -o /tmp/r8 -w '%{http_code}' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"pulocation_id":')" "$(cat /tmp/r8)"
echo "== 9. predict zone not an integer =="
show "$(curl -s -o /tmp/r9 -w '%{http_code}' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"pulocation_id":"abc","dolocation_id":230,"trip_miles":2.5,"trip_time_sec":1500,"driver_pay":28.5,"request_datetime":"2025-01-06T08:30:00Z"}')" "$(cat /tmp/r9)"
echo "== 10. recommend-start valid (Monday 08:30) =="
show "$(curl -s -o /tmp/r10 -w '%{http_code} t=%{time_total}s' -X POST $B/recommend-start -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"datetime":"2025-01-06T08:30:00Z","company":"Uber"}')" "$(cat /tmp/r10)"
echo "== 11. recommend invalid company =="
show "$(curl -s -o /tmp/r11 -w '%{http_code}' -X POST $B/recommend-start -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"datetime":"2025-01-06T08:30:00Z","company":"Taxi"}')" "$(cat /tmp/r11)"
echo "== 12. validate Uber Sunday 00:00 =="
show "$(curl -s -o /tmp/r12 -w '%{http_code} t=%{time_total}s' -X POST $B/validate-trip-start -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"company":"Uber","datetime":"2025-01-05T00:00:00Z","location_id":61}')" "$(cat /tmp/r12)"
echo "== 13. validate Lyft Monday 08:30 =="
show "$(curl -s -o /tmp/r13 -w '%{http_code} t=%{time_total}s' -X POST $B/validate-trip-start -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"company":"Lyft","datetime":"2025-01-06T08:30:00Z","location_id":61}')" "$(cat /tmp/r13)"
echo "== 14. unknown route with key =="
show "$(curl -s -o /tmp/r14 -w '%{http_code}' $B/nope -H "X-Internal-Key: $KEY")" "$(cat /tmp/r14)"
echo "== 15. CORS preflight from allowed origin =="
show "$(curl -s -o /tmp/r15 -D /tmp/h15 -w '%{http_code}' -X OPTIONS $B/predict -H 'Origin: http://localhost:3838' -H 'Access-Control-Request-Method: POST')" "$(grep -i 'access-control-allow-origin' /tmp/h15 | tr -d '\r' | head -1)"
echo "== 16. CORS Origin: null blocked =="
curl -s -o /dev/null -D /tmp/h16 -X OPTIONS $B/predict -H 'Origin: null' -H 'Access-Control-Request-Method: POST'; grep -ci 'access-control-allow-origin' /tmp/h16 || echo "no-allow-header (ok)"
echo "== 17. health after traffic =="
show "$(curl -s -o /tmp/r17 -w '%{http_code}' -H "X-Internal-Key: $KEY" $B/health)" "$(cat /tmp/r17)"
grep VmRSS /proc/$(pgrep -f "file=api/plumber" | head -1)/status
echo "== 18. predict warm x3 =="
for i in 1 2 3; do
  curl -s -o /tmp/r18 -w "t=%{time_total} " -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d "$PAYLOAD"
done
echo; echo "last: $(cat /tmp/r18)"
echo "== 19. POST without body =="
show "$(curl -s -o /tmp/r19 -w '%{http_code}' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json')" "$(cat /tmp/r19)"
echo "== 20. POST with text/plain =="
show "$(curl -s -o /tmp/r20 -w '%{http_code}' -X POST $B/predict -H "X-Internal-Key: $KEY" -H 'Content-Type: text/plain' -d 'x=1')" "$(cat /tmp/r20)"
echo "== 21. validate optimal JSON (no nulls) =="
show "$(curl -s -o /tmp/r21 -w '%{http_code}' -X POST $B/validate-trip-start -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"company":"Uber","datetime":"2025-01-05T00:00:00Z","location_id":61}')" "$(cat /tmp/r21)"
echo "== 22. sensitivity sin X-Client-IP =="
show "$(curl -s -o /tmp/r22 -w '%{http_code}' -X POST $B/sensitivity -H "X-Internal-Key: $KEY" -H 'Content-Type: application/json' -d '{"experiment_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","trip_id":87713555}')" "$(cat /tmp/r22)"
# Run-unique experiment_id so case 23 is a genuine cold miss (same UUID would
# reuse the value another run left in Redis).
SP="{\"experiment_id\":\"$(printf '00000000-0000-4000-8000-%012d' $(date +%s))\",\"trip_id\":87713555}"
echo "== 23. sensitivity cold (grid 50x50) =="
show "$(curl -s -o /tmp/r23 -w '%{http_code} t=%{time_total}s' -X POST $B/sensitivity -H "X-Internal-Key: $KEY" -H 'X-Client-IP: 1.2.3.4' -H 'Content-Type: application/json' -d "$SP")" "$(head -c 300 /tmp/r23)"
echo "== 24. sensitivity hit (caché Redis) =="
show "$(curl -s -o /tmp/r24 -w '%{http_code} t=%{time_total}s' -X POST $B/sensitivity -H "X-Internal-Key: $KEY" -H 'X-Client-IP: 1.2.3.4' -H 'Content-Type: application/json' -d "$SP")" "$(cmp -s /tmp/r23 /tmp/r24 && echo 'body identical to cold' || echo 'BODY DIFFERS')"
echo "== 25. sensitivity mobile (grid 30x30) =="
show "$(curl -s -o /tmp/r25 -w '%{http_code} t=%{time_total}s' -X POST $B/sensitivity -H "X-Internal-Key: $KEY" -H 'X-Client-IP: 1.2.3.4' -H 'X-Device: mobile' -H 'Content-Type: application/json' -d "$SP")" "$(python3 -c "import json;d=json.load(open('/tmp/r25'));print(len(d['grid_original']),'rows (900 expected)')")"
echo "== 26. sensitivity zonas explícitas (sugerencia null) =="
show "$(curl -s -o /tmp/r26 -w '%{http_code} t=%{time_total}s' -X POST $B/sensitivity -H "X-Internal-Key: $KEY" -H 'X-Client-IP: 1.2.3.4' -H 'Content-Type: application/json' -d '{"experiment_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","trip_id":87713555,"pickup_id":132,"dropoff_id":144}')" "$(python3 -c "import json;d=json.load(open('/tmp/r26'));print('suggested:',d['pickup_suggested'],d['dropoff_suggested'],'| pu_label:',d['meta']['pu_label'])")"
echo "== 27. sensitivity trip inexistente =="
show "$(curl -s -o /tmp/r27 -w '%{http_code}' -X POST $B/sensitivity -H "X-Internal-Key: $KEY" -H 'X-Client-IP: 1.2.3.4' -H 'Content-Type: application/json' -d '{"experiment_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","trip_id":1}')" "$(cat /tmp/r27)"
echo "== 28. RSS =="
rpid=$(pgrep -f "file=api/plumber" | head -1)
grep -E "VmRSS" /proc/$rpid/status
