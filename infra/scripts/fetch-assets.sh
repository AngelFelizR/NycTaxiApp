#!/usr/bin/env bash
# Download and VERIFY the model and dataset files of a release (master doc
# 4.5 and 15). Nothing is baked into an image: the deploy calls this once and
# the containers mount the result read-only.
#
#   MODELS_DIR=/srv/nyctaxi/models DATA_DIR=/srv/nyctaxi/data \
#     infra/scripts/fetch-assets.sh [tag]
#
# Aborts without touching anything if the checksum cannot be verified (4.5):
# a half-written 345 MB policy file would let the API start, load it and serve
# garbage, which is worse than not starting at all. Files already present and
# correct are left alone, so a re-run costs one HTTP request (the manifest).
set -euo pipefail

TAG="${1:-${DATA_RELEASE_TAG:-v0.0.1-data}}"
BASE_URL="${DATA_RELEASE_URL:-https://github.com/AngelFelizR/NycTaxiApp/releases/download}"

MODELS_DIR="${MODELS_DIR:-/srv/nyctaxi/models}"
DATA_DIR="${DATA_DIR:-/srv/nyctaxi/data}"

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

mkdir -p "$MODELS_DIR" "$DATA_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "release: $TAG"
if ! curl --fail --location --silent --show-error --retry 3 \
      --output "$TMP/SHA256SUMS" "${BASE_URL}/${TAG}/SHA256SUMS"; then
  cat >&2 <<EOF
FAIL: the release does not publish SHA256SUMS.
      Create one with (cd <directory> && sha256sum * > SHA256SUMS) and
      upload it to the release: section 4.5 requires verification before
      anything restarts.
EOF
  exit 1
fi

# The manifest must list everything before anything is downloaded: failing on
# the first missing file would make the operator fix the release one entry at
# a time, and 4.5 asks for verification, not for partial installs.
absent=()
for f in "${MODELS[@]}" "${DATA[@]}"; do
  grep -qE "[[:space:]]${f}$" "$TMP/SHA256SUMS" || absent+=("$f")
done
if (( ${#absent[@]} > 0 )); then
  {
    echo "FAIL: SHA256SUMS on the release does not list ${#absent[@]} of"
    echo "      $((${#MODELS[@]} + ${#DATA[@]})) expected files:"
    printf '        - %s\n' "${absent[@]}"
    echo "      Generate it with ./infra/scripts/make-manifest.sh and upload it"
    echo "      next to the files (docs/operations/first-deploy.md, section 1)."
  } >&2
  exit 1
fi

# Lookup by file name. sha256sum writes "<hash>  <name>" (two spaces).
hash_of() { awk -v f="$1" '$2 == f { print $1 }' "$TMP/SHA256SUMS"; }

verified() { # $1 = file to check, $2 = name whose hash to use
  local hash
  hash="$(hash_of "$2")"
  [[ -n "$hash" ]] || return 1
  echo "${hash}  ${1}" | sha256sum -c --status -
}

fetch() { # $1 = file name, $2 = destination directory
  local name="$1"
  local dir="$2"
  # Two `local`s on purpose: in one statement ${dir} would still be empty.
  local dest="${dir}/${name}"

  if [[ -f "$dest" ]] && verified "$dest" "$name"; then
    echo "ok       ${name} (already present)"
    return 0
  fi

  echo "download ${name} ..."
  curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --output "$TMP/$name" "${BASE_URL}/${TAG}/${name}"

  # Verify in the staging directory: the destination only ever receives bytes
  # that passed.
  if ! verified "$TMP/$name" "$name"; then
    echo "FAIL: checksum mismatch for ${name} -- nothing was written to ${dir}." >&2
    exit 1
  fi

  mv "$TMP/$name" "$dest"
  echo "ok       ${name}"
}

for f in "${MODELS[@]}"; do fetch "$f" "$MODELS_DIR"; done
for f in "${DATA[@]}";   do fetch "$f" "$DATA_DIR";   done

echo "assets ready: ${MODELS_DIR} (${#MODELS[@]} files), ${DATA_DIR} (${#DATA[@]} files)"
