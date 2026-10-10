# 0015. Third-party images are mirrored into our GHCR, because a Docker Hub token cannot reach them

- Status: Accepted
- Date: 2026-10-09
- Phase: 7 (§8.6 CI, §1.0 networks)
- Relates to: ADR-0001 (the service containers this keeps)

## Context

On 2026-10-09 the run of `main` for commit `252cad1` went red. Three of the
five test jobs failed and the three image builds plus the deploy were skipped
behind them, so the whole pipeline stopped. Read from the run page it looked
like the images this repository publishes could not be pulled.

They could. All four `ghcr.io/angelfelizr/nyc-taxi-*` packages are public and
carry `:latest` — verified anonymously, `GET .../manifests/latest` answers 200
for the development image and for all three deployment images, and
`.../tags/list` returns the tags without a credential. Nothing was wrong with
what we push.

What failed was everything else the jobs pull, and all of it from Docker Hub:

- `test-api`, `test-share` and `test-shiny` died in the step GitHub calls
  **"Initialize containers"**, which is where the `services:` of a job are
  pulled: `postgres:16-alpine`, `redis:7-alpine`, `axllent/mailpit:latest`.
- `test-contract` died on `docker run stoplight/spectral`.

The annotation for the first three is literally `Docker pull failed with exit
code 1`. Docker Hub rate-limits by client IP, and a GitHub-hosted runner shares
its IP with every other job on the host, so the limit is not ours to spend. The
run before it had gone green on the same images: that intermittency is the
signature of a shared-IP quota, not of a broken reference.

The tempting fix — authenticate to Docker Hub with a token — does not work, and
the reason is worth an ADR on its own. In a job with `services:`, the runner
pulls them as **step 1**, before `actions/checkout` and before
`docker/login-action` (which is step 3 in these jobs). The pull happens before
any step of ours can run, so no credential we provide can be in scope at the
moment it matters. This was confirmed against the real job graph of the failing
run, not against the documentation.

## Decision

The six third-party images this repository pulls are copied into
`ghcr.io/angelfelizr/*` by `.github/workflows/mirror-images.yml`, and
everything that consumes them — the CI jobs, the development compose and the
smoke test — is pointed at the mirror. Nothing in `.github/workflows/` pulls
from Docker Hub any more.

| Source (Docker Hub) | Mirror (GHCR) | Pulled by |
|---|---|---|
| `library/postgres:16-alpine` | `ghcr.io/angelfelizr/postgres:16-alpine` | `test-api`, `test-shiny` services |
| `library/redis:7-alpine` | `ghcr.io/angelfelizr/redis:7-alpine` | `test-api`, `test-shiny`, `test-share` services |
| `axllent/mailpit:latest` | `ghcr.io/angelfelizr/mailpit:latest` | `test-shiny` service |
| `stoplight/spectral:latest` | `ghcr.io/angelfelizr/spectral:latest` | `test-contract` |
| `library/alpine:latest` | `ghcr.io/angelfelizr/alpine:latest` | `smoke-stack.sh` network probes |
| `library/nginx:alpine` | `ghcr.io/angelfelizr/nginx:alpine` | the edge of `docker-compose.test.yml` |

Two properties of the copy are load-bearing and were verified, not assumed:

- **`docker buildx imagetools create` copies the blobs as well as the
  manifest.** It prints one `copying sha256:... from docker.io to ghcr.io` per
  layer, and the result is pullable. A manifest-only tool would have produced a
  reference that resolves and then fails at pull time — the worst kind of
  broken, because it looks fine until a job needs it.
- **It keeps every platform.** A `docker pull` / `tag` / `push` round trip
  would have pushed only the runner's architecture. The copies are whole.

A new package created by any push is **private** by default, and
"Initialize containers" runs with no login — so a private mirror is no better
than Docker Hub. **Changing that is a one-time, manual, web-UI action**, and
the reason it is manual is worth recording: GitHub's Packages REST API has no
endpoint that updates a package at all — checked against the whole reference,
which contains no `PATCH` route anywhere (`PATCH /users/{u}/packages/...`
answers 404 because the route does not exist, not because of a missing scope;
`GET` on the same path answers 200 and reports `"visibility":"private"`). The
workflow therefore **checks** the visibility after pushing and fails with the
exact URL to fix, rather than letting `test-api` fail minutes later with a bare
`Docker pull failed`:
`https://github.com/users/<owner>/packages/container/package/<name>` →
*Package settings* → *Change visibility* → *Public*. Six packages, once, ever.

## Alternatives

- **Authenticate to Docker Hub with a `DOCKERHUB_TOKEN` secret** — rejected
  because it cannot work for three of the four failures. The service containers
  are pulled as step 1 of the job, before any step of ours exists to log in.
  It would have fixed `test-contract` alone, which is not a fix.
- **Use the registries that already mirror these images** — `ghcr.io/axllent/mailpit`
  exists upstream (verified, 200) and AWS publishes the official Docker library
  images at `public.ecr.aws/docker/library/{postgres,redis}`. Rejected because
  it trades one dependency for three, none of them ours, and still leaves
  `stoplight/spectral` with nowhere to go. A single registry we control is
  easier to reason about than three we do not, and the total maintenance is one
  matrix in one workflow.
- **Drop `services:` and start the dependencies in a step** — then a login step
  *would* run before the pull, and a Docker Hub token would work. Rejected
  because it gives up what `services:` gives for free: the runner waits for the
  health checks and refuses to start the steps until Postgres and Redis answer,
  and that gating is exactly what ADR-0001 chose. Rewriting it as a compose
  file plus a polling loop is more moving parts for the same outcome.
- **Do nothing** — the run was red for a reason that would recur on every
  busy afternoon, and the workaround (re-run the workflow) is not one. Rejected.

## Consequences

- **The mirrors are copies, not live mirrors.** The weekly `schedule` refreshes
  them, so a bumped upstream version can be up to seven days behind. Bumping a
  version means editing **two** lists: the matrix here and the references in
  `.github/workflows/ci.yml`. A tag that is updated in place (`mailpit:latest`,
  `spectral:latest`, `alpine:latest`, `nginx:alpine`) is caught by the weekly
  run; a version bump (`postgres:17-alpine`) is not, and has to be done by hand.
- **`docker-compose.prod.yml` still pulls `nginx:alpine`, `postgres:16-alpine`
  and `redis:7-alpine` from Docker Hub**, along with
  `openanalytics/shinyproxy:3.2.4`. Deliberate: those run on the VM, which is
  not a rate-limited shared runner and which already pulls four of our images
  on every deploy. Changing the deployment file is a deploy-affecting change
  and does not belong in a fix for a red CI.
- **`test-contract` gained a `docker/login-action` step.** The spectral mirror
  is public and GHCR would serve it anonymously, but the login costs one step
  and removes the whole class of "the package turned private" failures.
- **Divergences:** none with the master document. §8.6 specifies the jobs and
  their order, not the registry the dependencies come from; §1.0 specifies the
  runtime networks, which this does not touch.

- **Follow-ups:** none blocking. The one worth remembering is that the
  development image is already public on GHCR and built by hand
  (`infra/scripts/dev-image.sh`), so it is not part of this mirror and does not
  need to be.
