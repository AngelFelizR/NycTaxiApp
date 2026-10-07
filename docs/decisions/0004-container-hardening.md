# 0004. Container hardening: no capabilities, read-only roots, unprivileged user

- Status: Accepted
- Date: 2026-10-07
- Phase: 7 (infra & deploy) — master document §1.1, §5.10, §9.3
- Relates to: ADR-017 (API private, public `share`, three Docker networks)

## Context

An external review of phase 7 found that every container ran as root with
every capability, a writable root filesystem, no process limit, and a
healthcheck that started a full R interpreter every 30 seconds inside a
container limited to 1.5 GB. Section 1.1 fixes memory and CPU but says nothing
about any of that, and section 5.10 makes `share/` the only service reachable
from the Internet while `api/` holds every secret in the stack.

Two facts shape what is possible here:

- **ShinyProxy's Shiny containers are not ours to configure.** Section 8.3
  exposes `container-volumes`, `container-env`, `container-memory-limit` and
  `container-cpu-limit`, and nothing for capabilities or a read-only root.
- **The Nix base image has no `useradd`, and `/etc/passwd` is a symlink into
  the store**, so a named account would mean replacing a store path. It also
  puts `wget`/`curl` under `/root/.nix-profile`, which a non-root user cannot
  traverse.

## Decision

1. **All six compose services drop every capability** and add back only what
   their entrypoints really use: nginx needs `CHOWN/SETUID/SETGID/
   DAC_OVERRIDE/FOWNER/NET_BIND_SERVICE`, postgres and redis need the first
   five to chown their data directory, and the three images we build need
   nothing at all (they bind above 1024 and write only under `/tmp`). Every
   service also gets `pids_limit` and `no-new-privileges`.
2. **`read_only: true` everywhere, with an explicit `tmpfs` for what each
   service writes**: `/tmp` for api, share and redis; `/var/run` and
   `/var/cache/nginx` for nginx; `/var/run/postgresql` for postgres;
   `/tmp`, `/root/.cache` and `/root/.java` for ShinyProxy.
3. **The three images run as `USER 65534:65534`** with
   `HOME=/tmp` and `XDG_CACHE_HOME=/tmp/.cache` -- a numeric id, no
   `/etc/passwd` entry, because everything R writes (fontconfig, bslib's font
   cache, Shiny session files, `tempdir()`) goes to `/tmp`, which (2) declares
   as a tmpfs.
4. **The API healthcheck uses `curl`, not `Rscript`.** `curl` moves into
   `nix/system.nix` so it lands in `/opt/system/bin`, which is world-readable
   and first on `PATH`; the probe reads `$$API_INTERNAL_KEY` so the command in
   `docker inspect` shows a variable name and never the value.
5. **Content-Security-Policy on the two static pages**: `script-src 'none'` on
   `/share/*` (section 7.2 says that page is never JavaScript, and this makes
   it a guarantee rather than a promise) and a tight policy on
   `capacity-full.html`, which does run one inline script for the waitlist
   form. Plus `/.well-known/security.txt`.

## Alternatives

- **Keep everything root with full capabilities** -- the state before this ADR.
  Rejected: a remote code execution in the Internet-facing service is already
  root in its container, and `share/` reaching Redis would then be the least
  of it. The cost of hardening was one afternoon and a smoke test.
- **Rootless Docker, or ShinyProxy on its own VM** so its containers could be
  hardened too. Rejected for now: it changes the deployment topology
  (`internal-networking`, three networks of §1.0) to solve a problem that
  affects only the ephemeral Shiny instances, and there is one deployment.
- **Replace the Docker socket with the API over TLS.** Rejected: it is the
  same authority over a different transport -- anything that can create
  containers can start one with `-v /:/host`, so the socket is not what makes
  ShinyProxy dangerous.
- **CSP on the Shiny application as well.** Deferred rather than rejected: a
  wrong `script-src` or `connect-src` silently breaks Shiny (the app relies on
  inline handlers and a WebSocket), and the smoke test has no browser to
  notice. It needs a check that drives a real session first -- see the
  follow-ups.

## Consequences

- **ShinyProxy keeps `/var/run/docker.sock`.** It is how it creates
  containers, there is no supported alternative in its docker backend, and
  TLS would not reduce the privilege. Accepted: compromising ShinyProxy means
  root on the host. Recorded here so the risk is chosen rather than
  overlooked; the mitigation is that it is the only service holding the
  socket and it is behind Nginx.
- **The ephemeral Shiny containers are not hardened** by (1)-(3): ShinyProxy
  creates them with Docker defaults. They hold no secrets beyond
  `API_INTERNAL_KEY`, which the API requires anyway, and they join only
  `nyctaxi_api_net` (§1.0, and asserted by the smoke test).
- **The CSP on `/` is still missing.** Add it only alongside a browser-driven
  check that a Shiny session connects, renders and keeps its WebSocket.
- `nix/system.nix` now carries `curl`, so it is part of every image and every
  shell. Rebuilds after a change to it re-run the R package layers (the build
  store is empty), which is why the file is deliberately small.
