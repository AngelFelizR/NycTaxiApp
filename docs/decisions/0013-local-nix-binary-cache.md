# 0013. The development image is fed by a signed local Nix binary cache

- Status: Accepted
- Date: 2026-10-08
- Phase: 7 (§1.1 image size, §8.6 build and CI time)
- Relates to: ADR-0011 (`nix/r-slim.nix`, whose new derivation started this),
  ADR-0008 (the system layer that was rebuilt alongside it), ADR-0012 (Cypress
  is the layer that landed in the same push)

## Context

Changing anything in `nix/` invalidates every Docker layer below it, and the
layers below are where the compile happens. The build of 2026-10-08, the one
that introduced `nix/r-slim.nix`, measured:

| Layer | What ran | Time |
|---|---|---|
| `nix/r-api.nix` | 134 derivations built, 400 paths / 824.9 MiB fetched | **1098.7 s** |
| `nix/system.nix` | `R-4.6.1` built (t=122 s → t=869 s) + 646 paths / 1.1 GiB | **875.4 s** |
| `api` + `share` shells | 11 + 5 derivations, 485 paths / 281 MiB | 582.2 s |
| `nix/r-dev.nix` | 37 derivations, 202 paths / 1.3 GiB | 297.3 s |

3223 s of layer time (54 min) plus the push of 9 GB: **~64 minutes**, 47 of
them in those four layers. The user's ceiling for a build is 30 minutes.

The public caches do not cover it. Probing them with real store paths from
that build, not with assumptions:

- `rstats-on-nix.cachix.org` answers and is public (`nix-cache-info` → 200),
  but of the 400 paths the API layer fetched, **6 came from it and 394 from
  `cache.nixos.org`**.
- `r-purrr-1.2.2` (pin 2026-09-28) → 200 on `cache.nixos.org`.
  `r-purrr-1.2.0` and the `R-4.5.2` of the API pin (2025-12-02) → **404 on
  both caches**.
- `nix/r-slim.nix` (ADR-0011) deliberately changed R's derivation, so
  `R-4.6.1` is no longer the binary `rstats-on-nix` built either.

Docker's layer cache cannot be the answer, and it was working: 8 layers came
back `CACHED`. A layer that has to re-execute runs on the store *as it is at
that point*, which does not contain what the previous image built **in that
same layer** — the API packages exist only in the API layer, which is exactly
the one being invalidated. Replaying layers replays the compile.

## Decision

The development image carries a Nix binary cache on the build host:
`~/.cache/nyctaxi-nixcache` (override with `NYCTAXI_NIX_CACHE`), signed with a
keypair, served over loopback for the duration of the build, and fed from the
image that was just built.

- **`/etc/nix/nix.conf`** gains `extra-substituters = http://127.0.0.1:8093`
  and `extra-trusted-public-keys = nyctaxi-dev-cache:…`. `extra-` matters: a
  second plain `substituters =` line *replaces* the first, verified with
  `NIX_CONF_DIR`.
- **`dev-image.sh build`** = start the server → `docker build
  --network=host` → feed → `docker push` → stop the server (an `EXIT` trap, so
  a failed build does not leave it behind).
- **The feed** resolves every profile (`/nix/profiles/*`,
  `/nix/var/nix/profiles/*`, `per-user/root/*`) to store paths, signs their
  closure with `nix store sign --key-file`, and `nix copy --to
  "file:///cache?compression=zstd&parallel-compression=1"`. The profiles are
  the right roots because every layer ends in `nix-collect-garbage -d`, so the
  store *is* their closure. `nix copy` skips what the destination already has,
  so a build that changed nothing feeds nothing.
- **Signing is not optional.** `nix copy --option secret-key-files` does not
  sign (verified: the narinfo came out without a `Sig:`), and Nix 3.23 has no
  `--signer`; `nix store sign` before the copy is the sequence that works, and
  a clean store with `require-sigs = true` accepts the result.

Measured on the rebuild that landed this, same `nix-hash`:

| | before | after |
|---|---|---|
| sum of layer times | 3223 s (54 min) | **347 s (5 min)** |
| `nix/r-api.nix` | 1098.7 s, 134 built | **36.9 s, 0 built** |
| `nix/system.nix` | 875.4 s, `R-4.6.1` built | **44.7 s, 0 built** |
| paths fetched from the loopback cache | — | 1052 |
| derivations built in the whole run | — | 1 (`user-environment.drv`, a symlink farm) |
| image size | 8.97 GB | 8.91 GB |

9.3× on the layers. The seed itself took **~2 minutes**: the 7 GB store → 1137
paths → 2.6 GB of cache, all signed (`narinfo_sin_firma=0`, 0 missing NARs).

## Alternatives

- **A hosted binary cache (cachix or similar)** — rejected because it needs an
  account and a token that live outside this repository, and **CI never builds
  this image**: it is built here by hand and pulled by the runners, so nothing
  off this machine would ever read it. This becomes the answer the moment a
  second machine has to build.
- **The cache on the deployment VM** — rejected for now: the VM is not
  deployed (`docs/operations/first-deploy.md` is blocked on credentials), and
  the requirement as stated is that *this* machine stops paying.
- **BuildKit's registry cache (`--cache-to type=registry,mode=max`)** —
  rejected, and it was tried rather than assumed. It does not address the
  cause (it replays layers, and the layer that has to re-run is exactly the
  one that compiles the packages), the `docker` driver refuses it outright
  (*"Cache export is not supported for the docker driver"*), and GHCR does
  accept the export — the incompatibility is the other end: with the
  `docker-container` driver the substituter is unreachable. Measured with a
  probe, not a full build: `--network=host` still lands the `RUN` on
  `172.17.0.2` via `172.17.0.1`, `127.0.0.1` fails, and
  `--add-host=…:host-gateway` errors with *"host-gateway is not supported by
  the docker-container driver"*. The only route left is hardcoding the docker0
  gateway in `nix.conf` and binding the server beyond loopback, which breaks
  silently wherever the bridge is not `172.17.0.1`. Worth roughly 4–6 minutes
  on the rare occasions the local layer cache is lost — not worth that.
- **Revert `nix/r-slim.nix`** so R comes from the public cache — rejected: it
  puts the 1.34 GB of toolchain back into every image (undoing ADR-0011) and
  it would not help the API layer, which misses on its own pin anyway.
- **`require-sigs = false` instead of a keypair** — rejected because it turns
  off signature verification for `cache.nixos.org` as well, to save four
  lines. The measured cost of doing it properly was one `nix store sign`.
- **A BuildKit cache mount (`RUN --mount=type=cache`) instead of loopback**
  — the one that would keep the network mode out of the layer key (see
  Consequences). Rejected for now because it has to be added to every Nix
  `RUN`, and a `file:///nix-cache` substituter that only exists inside a build
  is one more thing to explain than a URL that is simply not listening.
- **`nix-collect-garbage -d` once at the end instead of once per layer** —
  rejected (and explicitly re-considered, then dropped): a GC in the same
  `RUN` that creates the garbage removes it *before* the layer is computed, so
  it never enters the diff. A single final GC would leave the data in the
  earlier layers and only write whiteouts: the merged image weighs the same,
  but what CI *pulls* grows. The savings would also be small — the re-fetched
  paths in the log belong to different closures, not to garbage.
- **Do nothing** — rejected: `nix/` has to change (ADR-0011 and ADR-0012 were
  written the same day) and every change was costing an hour.

## Consequences

- **`--network=host` is part of every `RUN`'s cache key.** The first build
  with it re-ran the `apt` layer (53.3 s) and the Nix installer (20.9 s) that
  had been `CACHED`; from then on it is stable, but a manual `docker build`
  **without** the flag invalidates everything again. `dev-image.sh` always
  passes it, and that is the documented way to build this image.
- **The keypair cannot be regenerated on its own.** Its public half is
  hardcoded in the Dockerfile, so a new pair means replacing both halves and
  accepting a rebuild (which the cache itself now makes cheap).
  `dev-image.sh build` fails loudly if `signing.key` is missing rather than
  silently feeding nothing.
- **The cache is written by the container as root**, so its files are
  root-owned inside the user's home. They are world-readable — the server runs
  as the user and can serve them — but reclaiming the space needs a root
  container: `docker run --rm -v "$CACHE_DIR:/cache" alpine rm -rf
  /cache/nar`. The feed then rebuilds it from the image.
- **`zstd`, not Nix's default `xz`.** The `xz` attempt wrote 592 MB of NAR in
  13 minutes **without completing a single path** — the narinfo is written
  last, so a killed feed leaves only orphans. The compression of a path lives
  in its narinfo, so a cache can hold both kinds.
- **A build without the server is correct but slow**, not broken: Nix
  re-queries `nix-cache-info` once and moves on (measured: ~1 s for a dead
  port, with and without a second substituter).
- **No divergence with the master document.** The cache holds build artefacts
  on the builder; it changes no runtime surface, no endpoint and no data path
  (§4.5 still says the only inputs are `MODELS_DIR` and `DATA_DIR`).

- **Follow-ups:** feed the three deployment Dockerfiles too — they run the
  same `nix-build`s and pay the same miss. Revisit the registry cache if a
  second machine ever has to build.
