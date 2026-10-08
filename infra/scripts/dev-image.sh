#!/usr/bin/env bash
# The development image: built where it changes, verified where it is used.
#
#   ./infra/scripts/dev-image.sh build    # local: build + push :latest
#   ./infra/scripts/dev-image.sh check    # CI: refuse to test against a stale one
#
# CI runs every suite inside ghcr.io/angelfelizr/nyc-taxi-dev:latest, so the
# image has to match the nix/ directory of the checkout being tested. nix/
# changes far less often than the code -- which is why the image is built by
# hand and CI only pulls -- but "far less often" is not "never", and a test
# run against an environment built from different pins is worse than no test
# run at all: it fails, or passes, for a reason that is not in the commit.
#
# The guard is a label carrying a hash of nix/ (filenames included, so a
# rename counts), computed the same way on both sides.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/angelfelizr/nyc-taxi-dev:latest}"

# Sorted by the shell's glob, so the value depends on the directory contents
# and their names, not on the order the files happen to be read in.
nix_hash() { sha256sum nix/* | sha256sum | cut -c1-16; }

case "${1:-}" in
  build)
    expected=$(nix_hash)
    echo "building $IMAGE for nix-hash=$expected"
    docker build --label "nix-hash=$expected" -t "$IMAGE" .
    docker push "$IMAGE"
    echo "pushed $IMAGE (nix-hash=$expected)"
    ;;
  check)
    expected=$(nix_hash)
    # docker inspect prints the template even when it fails, so the label is
    # cleaned before comparing: an absent image has to read "missing", not an
    # empty line.
    actual=$(docker inspect -f '{{index .Config.Labels "nix-hash"}}' \
               "$IMAGE" 2>/dev/null | tr -d '[:space:]' || true)
    actual=${actual:-missing}
    if [ "$actual" != "$expected" ]; then
      echo "::error title=stale development image::$IMAGE carries nix-hash=$actual but this checkout hashes to $expected. The tests would run against an environment built from different pins. Rebuild and push it: ./infra/scripts/dev-image.sh build" >&2
      exit 1
    fi
    echo "development image matches this checkout's nix/ ($expected)"
    ;;
  *)
    echo "usage: $0 build|check" >&2
    exit 2
    ;;
esac
