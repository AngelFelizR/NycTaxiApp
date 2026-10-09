#!/usr/bin/env bash
# Dev-only smoke for dev/load_sessions.js: five synthetic days, and the same
# five with one experiment id duplicated -- the cross-talk case (6.1.5) that
# must make the analyzer fail. No stack, no browser, no network: this file is
# the reason a bug in the assertions shows up in two seconds instead of an
# hour into a real load run.
#
#   bash dev/load_sessions.selftest.sh
set -euo pipefail
cd "$(dirname "$0")"   # this file lives in dev/, so load_sessions.js is here too

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

good="$tmp/good.jsonl"
: > "$good"
for i in 1 2 3 4 5; do
  strat=accept-all
  following=84
  rejected=0
  if [ $((i % 2)) -eq 0 ]; then strat=model-only; following=100; rejected=3; fi
  cat >> "$good" <<EOF
{"load_id":"$i","strategy":"$strat","client_ip":"203.0.113.$((100 + i))","exp_id":"00000000-0000-4000-8000-00000000000$i","started_at":"2026-10-08T12:0$i:00Z","finished_at":"2026-10-08T12:2$i:00Z","clicks":10,"accepted":$((10 - rejected)),"rejected":$rejected,"following":$following,"model_reject_offers":2,"sensitivity":true}
EOF
done

echo "== the good run must pass =="
node load_sessions.js "$good" 5 both > "$tmp/good.out"
grep -q "session assertions passed" "$tmp/good.out"

echo "== a duplicated experiment id must fail =="
bad="$tmp/bad.jsonl"
sed 's/00000000-0000-4000-8000-000000000005/00000000-0000-4000-8000-000000000004/' \
  "$good" > "$bad"
if node load_sessions.js "$bad" 5 both > "$tmp/bad.out"; then
  echo "FAIL: two sessions shared an experiment id and the analyzer passed" >&2
  exit 1
fi
grep -q "share experiment ids" "$tmp/bad.out"

echo "== a missing session must fail =="
head -4 "$good" > "$tmp/short.jsonl"
if node load_sessions.js "$tmp/short.jsonl" 5 both > "$tmp/short.out"; then
  echo "FAIL: four records for five sessions and the analyzer passed" >&2
  exit 1
fi
grep -q "expected 5 session records, got 4" "$tmp/short.out"

echo "== model-only that did not follow the policy must fail =="
awk -F'"' '{
  # flip one model-only row to following=84 without touching anything else
}1' "$good" > "$tmp/nofollow.jsonl"
sed -i 's/"strategy":"model-only","client_ip":"203.0.113.102"[^}]*"following":100/"strategy":"model-only","client_ip":"203.0.113.102","exp_id":"00000000-0000-4000-8000-000000000002","started_at":"2026-10-08T12:02:00Z","finished_at":"2026-10-08T12:22:00Z","clicks":10,"accepted":7,"rejected":3,"following":84/' \
  "$tmp/nofollow.jsonl"
if node load_sessions.js "$tmp/nofollow.jsonl" 5 both > "$tmp/nofollow.out"; then
  echo "FAIL: model-only at 84% following and the analyzer passed" >&2
  exit 1
fi
grep -q "not 100" "$tmp/nofollow.out"

echo "load_sessions.js behaves: passes the good run, rejects cross-talk,"
echo "a missing session, and a strategy that was not followed."
