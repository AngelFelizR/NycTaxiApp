#!/usr/bin/env bash
# Build the SHA256SUMS manifest for the data release (section 4.5).
#
#   ./infra/scripts/make-manifest.sh [output-path]
#
# The release holds six flat files; locally they live in two directories
# ($MODELS_DIR and $DATA_DIR), so a plain `sha256sum *` in either one would
# cover only half of them. The manifest that goes on the release must list all
# six by bare name -- that is what fetch-assets.sh verifies against.
#
# After generating it, upload it together with ReferenceDistribution.qs2:
#   see docs/operations/first-deploy.md, section 1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# The environment wins, then .env -- so the self-test can point both at
# fixtures without touching the real .env. Written out by hand rather than in
# a loop over names: eval cannot be followed by static analysis and printf -v
# is no clearer for two variables.
if [[ -z "${MODELS_DIR:-}" ]]; then
  MODELS_DIR="$(grep -m1 '^MODELS_DIR=' .env 2>/dev/null | cut -d= -f2- || true)"
fi
if [[ -z "${DATA_DIR:-}" ]]; then
  DATA_DIR="$(grep -m1 '^DATA_DIR=' .env 2>/dev/null | cut -d= -f2- || true)"
fi
for v in MODELS_DIR DATA_DIR; do
  if [[ -z "${!v:-}" || ! -d "${!v}" ]]; then
    echo "FAIL: ${v} is not a directory (got: '${!v:-}')" >&2
    exit 1
  fi
done

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

OUT="${1:-$ROOT/SHA256SUMS}"

missing=0
for f in "${MODELS[@]}" "${DATA[@]}"; do
  found=""
  [[ -f "$MODELS_DIR/$f" ]] && found="$MODELS_DIR/$f"
  [[ -z "$found" && -f "$DATA_DIR/$f" ]] && found="$DATA_DIR/$f"
  if [[ -z "$found" ]]; then
    echo "MISSING: $f" >&2
    missing=$((missing + 1))
  fi
done
if (( missing > 0 )); then
  echo "FAIL: $missing file(s) not present; nothing was written." >&2
  echo "      ReferenceDistribution.qs2 is produced by" >&2
  echo "      tools/build_reference_distribution.R (~75 min)." >&2
  exit 1
fi

: >"$OUT"
for f in "${MODELS[@]}"; do
  (cd "$MODELS_DIR" && sha256sum "$f") >>"$OUT"
done
for f in "${DATA[@]}"; do
  (cd "$DATA_DIR" && sha256sum "$f") >>"$OUT"
done

echo "wrote $OUT:"
cat "$OUT"
echo
echo "next: upload it and ReferenceDistribution.qs2 to the release --"
echo "      see docs/operations/first-deploy.md, section 1."
