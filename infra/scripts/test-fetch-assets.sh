#!/usr/bin/env bash
# Self-test for the two release-asset scripts (master doc 4.5), hermetic: it
# invents six small files, so it runs anywhere -- no 558 MB download, no
# network, no real .env.
#
#   ./infra/scripts/test-fetch-assets.sh
#
# It exists because "the deploy aborts when it cannot verify" is only a
# guarantee if something proves the verifier works: this covers the happy
# path, the idempotent re-run, a manifest missing entries, and a wrong hash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MODELS_DIR="$WORK/models"
DATA_DIR="$WORK/data"
RELEASE="$WORK/release/v0.0.1-data"
OUT_M="$WORK/out-models"
OUT_D="$WORK/out-data"
mkdir -p "$MODELS_DIR" "$DATA_DIR" "$RELEASE" "$OUT_M" "$OUT_D"

MODELS=(
  AcceptRejectPolicyFitted.qs2
  DecisionTreeWfFitted.qs2
  ValidHoursToStartWorking.qs2
  ReferenceDistribution.qs2
)
DATA=(
  NycTrips2024_sample_week.parquet
  ZonesShapes.qs2
)

fails=0
say() { echo; echo "== $1 =="; }
check() { # <expected> <actual> <label>
  if [[ "$1" == "$2" ]]; then
    echo "  ok:   $3 = $2"
  else
    echo "  FAIL: $3 = $2 (expected $1)"
    fails=$((fails + 1))
  fi
}

# The files the release would carry; content is irrelevant, only hashing is.
for f in "${MODELS[@]}"; do printf 'model-bytes for %s' "$f" >"$MODELS_DIR/$f"; done
for f in "${DATA[@]}";   do printf 'data-bytes for %s'  "$f" >"$DATA_DIR/$f";  done

# ------------------------------------------------------------------ manifest
say "make-manifest.sh lists all six files"
MODELS_DIR="$MODELS_DIR" DATA_DIR="$DATA_DIR" \
  "$ROOT/infra/scripts/make-manifest.sh" "$RELEASE/SHA256SUMS" >/dev/null
check 6 "$(wc -l <"$RELEASE/SHA256SUMS")" "entries in SHA256SUMS"
for f in "${MODELS[@]}" "${DATA[@]}"; do cp "$MODELS_DIR/$f" "$RELEASE/$f" 2>/dev/null || cp "$DATA_DIR/$f" "$RELEASE/$f"; done

fetch() { # <models-dir> <data-dir>
  DATA_RELEASE_URL="file://$WORK/release" MODELS_DIR="$1" DATA_DIR="$2" \
    "$ROOT/infra/scripts/fetch-assets.sh" "v0.0.1-data"
}

# ---------------------------------------------------------------- happy path
say "fetch-assets.sh installs and verifies everything"
out="$(fetch "$OUT_M" "$OUT_D" 2>&1)" && rc=0 || rc=$?
check 0 "$rc" "exit code"
check 6 "$(( $(find "$OUT_M" -type f | wc -l) + $(find "$OUT_D" -type f | wc -l) ))" "files installed"
if grep -q "assets ready" <<<"$out"; then
  echo "  ok:   reports success"
else
  echo "  FAIL: no success line"
  fails=$((fails + 1))
fi

# ------------------------------------------------------------- idempotency
say "a second run downloads nothing"
out="$(fetch "$OUT_M" "$OUT_D" 2>&1)" && rc=0 || rc=$?
check 0 "$rc" "exit code"
check 6 "$(grep -c "already present" <<<"$out")" "files recognised as present"

# -------------------------------------------------- manifest missing entries
say "a manifest missing entries fails and names every one of them"
cp "$RELEASE/SHA256SUMS" "$WORK/SHA256SUMS.bak"
grep -vE "(ZonesShapes|ValidHours)" "$WORK/SHA256SUMS.bak" >"$RELEASE/SHA256SUMS"
rm -rf "${OUT_M:?}"/* "${OUT_D:?}"/*
out="$(fetch "$OUT_M" "$OUT_D" 2>&1)" && rc=0 || rc=$?
check 1 "$rc" "exit code"
if grep -q "ZonesShapes.qs2" <<<"$out" && grep -q "ValidHoursToStartWorking.qs2" <<<"$out"; then
  echo "  ok:   both missing files are named"
else
  echo "  FAIL: missing files not reported: $out"
  fails=$((fails + 1))
fi
check 0 "$(( $(find "$OUT_M" -type f | wc -l) + $(find "$OUT_D" -type f | wc -l) ))" \
  "files installed (must be none: it aborts before writing)"

# ------------------------------------------------------------------ bad hash
say "a wrong hash fails and the destination file is not written"
cp "$WORK/SHA256SUMS.bak" "$RELEASE/SHA256SUMS"
sed -i 's/^./f/' "$RELEASE/SHA256SUMS"   # corrupt every digest
rm -rf "${OUT_M:?}"/* "${OUT_D:?}"/*
out="$(fetch "$OUT_M" "$OUT_D" 2>&1)" && rc=0 || rc=$?
check 1 "$rc" "exit code"
if grep -qi "mismatch" <<<"$out"; then
  echo "  ok:   reports a checksum mismatch"
else
  echo "  FAIL: no mismatch reported: $out"
  fails=$((fails + 1))
fi
check 0 "$(( $(find "$OUT_M" -type f | wc -l) + $(find "$OUT_D" -type f | wc -l) ))" \
  "files installed (must be none: 4.5 says abort, not partially install)"

echo
if (( fails == 0 )); then
  echo "ALL OK"
else
  echo "$fails check(s) FAILED"
  exit 1
fi
