#!/usr/bin/env bash
# The development image: built where it changes, verified where it is used.
#
#   ./infra/scripts/dev-image.sh build    # local: build + feed cache + push :latest
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
#
# The build also feeds a Nix binary cache on the host. Both public caches miss
# on R 4.6.1 (nix/r-slim.nix) and on the R packages of the 2025-12-02 API pin,
# so a layer invalidation would otherwise recompile them: 747 s for R inside
# system.nix and 1099 s for 134 R packages inside r-api.nix. See ADR-0013.
#
# There is deliberately no BuildKit registry cache here. It needs the
# docker-container driver, and that driver cannot reach the host: `--network=host`
# leaves the RUN step on 172.17.0.2 and `--add-host ...:host-gateway` fails
# outright ("host-gateway is not supported by the docker-container driver"),
# so the loopback substituter goes unused and the whole point is lost. The
# docker driver is the one that can do this job.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/angelfelizr/nyc-taxi-dev:latest}"
CACHE_DIR="${NYCTAXI_NIX_CACHE:-$HOME/.cache/nyctaxi-nixcache}"
CACHE_PORT="${NYCTAXI_NIX_CACHE_PORT:-8093}"
CACHE_URL="http://127.0.0.1:${CACHE_PORT}"
CACHE_PID=""

# The order has to be pinned, not inherited: a shell glob follows LC_COLLATE,
# and en_US.UTF-8 sorts "r-shared" before "r-share" while C sorts it after --
# the same directory then hashes differently on a laptop and on a runner, and
# the check fails for content that is identical. LC_ALL=C everywhere.
nix_hash() {
  find nix -maxdepth 1 -type f | LC_ALL=C sort | \
    xargs -r sha256sum | sha256sum | cut -c1-16
}

# Serve the cache for the duration of the build. The Dockerfile hardcodes
# 127.0.0.1:$CACHE_PORT and the build runs with --network=host, which is what
# makes it reachable -- and is part of every RUN's cache key, so it has to be
# passed every time. Nix re-queries nix-cache-info once when nothing is
# listening and moves on (measured: ~1 s), which is what keeps a manual
# `docker build` correct-but-slow instead of broken.
cache_start() {
  mkdir -p "$CACHE_DIR"
  if curl -sf --max-time 2 "$CACHE_URL/nix-cache-info" >/dev/null 2>&1; then
    echo "binary cache already serving $CACHE_URL"
    return 0
  fi
  python3 -m http.server "$CACHE_PORT" --bind 127.0.0.1 \
    --directory "$CACHE_DIR" >/dev/null 2>&1 &
  CACHE_PID=$!
  local _i
  for _i in $(seq 1 50); do
    if curl -sf --max-time 1 "$CACHE_URL/nix-cache-info" >/dev/null 2>&1; then
      echo "serving $CACHE_DIR on $CACHE_URL"
      return 0
    fi
    kill -0 "$CACHE_PID" 2>/dev/null || break
    sleep 0.2
  done
  echo "error: could not start the binary cache on $CACHE_URL" >&2
  exit 1
}

cache_stop() {
  if [ -n "$CACHE_PID" ]; then
    kill "$CACHE_PID" 2>/dev/null || true
    wait "$CACHE_PID" 2>/dev/null || true
  fi
}

# Push what the image holds into the cache, signed with the key whose public
# half is baked into the Dockerfile. Profiles are the roots: every layer ends
# in `nix-collect-garbage -d`, so the store is exactly their closure. Paths
# already in the cache are skipped, so a build that changed nothing feeds
# nothing.
#
# The URI asks for zstd: Nix's default is xz, which wrote 592 MB of NAR in 13
# minutes without finishing a single path -- the narinfo is written last, so a
# killed feed leaves only orphans -- against ~2 minutes for the whole 7 GB
# store. The compression of a path lives in its narinfo, so a cache can hold
# both kinds.
cache_feed() {
  if [ ! -f "$CACHE_DIR/signing.key" ]; then
    echo "error: $CACHE_DIR/signing.key is missing. It signs the cache and cannot be recreated on its own: the public half is hardcoded in the Dockerfile (extra-trusted-public-keys), so a new pair would invalidate every layer. Restore the file, or replace both halves together and accept one full rebuild." >&2
    exit 1
  fi
  echo "feeding the binary cache from $IMAGE"
  docker run --rm \
    -v "$CACHE_DIR:/cache" \
    -v "$CACHE_DIR/signing.key:/signing.key:ro" \
    "$IMAGE" bash -lc '
      set -euo pipefail
      roots=()
      p= r=
      for p in /nix/profiles/* /nix/var/nix/profiles/* \
               /nix/var/nix/profiles/per-user/root/*; do
        [ -e "$p" ] || continue
        r=$(readlink -f "$p")
        case "$r" in /nix/store/*) roots+=("$r") ;; esac
      done
      if [ "${#roots[@]}" -eq 0 ]; then
        echo "no nix profiles in the image" >&2
        exit 1
      fi
      mapfile -t closure < <(nix-store -qR "${roots[@]}")
      nix store sign --key-file /signing.key "${closure[@]}" >/dev/null
      nix copy --to "file:///cache?compression=zstd&parallel-compression=1" \
        "${roots[@]}"
    '
}

case "${1:-}" in
  build)
    expected=$(nix_hash)
    echo "building $IMAGE for nix-hash=$expected"
    cache_start
    trap cache_stop EXIT
    docker build --network=host --label "nix-hash=$expected" -t "$IMAGE" .
    cache_feed
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
