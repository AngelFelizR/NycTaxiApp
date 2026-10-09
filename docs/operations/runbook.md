# Operations runbook

Living document (master doc §8.8). It starts with the four procedures the
document prescribes and grows as incidents happen: when one does, add it here
rather than keeping it in a chat log.

Every entry uses the same shape:

```markdown
## Incident: [name]

**Symptom:** ...
**Diagnosis:** ...
**Fix:** ...
**Prevention:** ...
```

Conventions used below:

- Commands are run **on the VM** from the repository root (`~/NycTaxiApp`),
  unless stated otherwise.
- `.env` is the single root file with every secret (§1.2). It is gitignored.
- `docker compose -f docker-compose.prod.yml` is the deployment stack;
  `docker compose` alone is the development stack and must never be used to
  start production (it publishes 2222/5432/6379).

---

## Incident: disk full

**Symptom:** `infra/scripts/disk_check.sh` mailed `disk NN% on /` (it runs
hourly from cron and alerts above 80%). Symptoms alongside it: Postgres
rejecting writes, Redis evicting the sensitivity cache, or Docker failing to
write a layer.

**Diagnosis:**

```sh
df -h / /srv/nyctaxi /var/lib/docker 2>/dev/null
docker system df                      # images, containers, volumes, build cache
du -xh --max-depth=2 /var/lib/docker /var/log /backups 2>/dev/null | sort -h | tail
docker ps --format '{{.Names}} {{.Status}}'
```

**Fix, in this order** (each step is safe to stop at):

1. Old images and the build cache — the cheapest gigabytes, nothing running
   depends on them:

   ```sh
   docker image prune -a --filter "until=168h"   # images unused for a week
   docker builder prune --filter "until=168h"
   ```

2. Rotated logs. The compose stack caps each service at 500 MB x 3 (§8.1), so
   ~1.5 GB/service is the ceiling; anything beyond that is outside compose:

   ```sh
   sudo journalctl --vacuum-size=200M
   du -sh /var/log/*
   ```

3. Expired backups. Retention is 28 days and `backup.sh` enforces it, but a
   cron that never ran leaves everything behind:

   ```sh
   ls -lah /backups
   find /backups -name 'nyctaxi_*.dump*' -mtime +28 -delete
   ```

4. Only then consider volumes. **Never `docker volume prune`**: `pgdata` holds
   every experiment and every waitlist email.

Afterwards confirm the alert clears (a green `disk_check.sh` run removes the
cooldown file, so the next incident alerts immediately).

**Prevention:** the hourly cron and the 28-day retention. Check `df -h` after
any deploy that adds images, and treat `/backups` growth as predictable rather
than surprising.

---

## Incident: delete a person's PII on request (§9.1)

**Symptom:** someone asks (by the contact address in the privacy notice) to
have their email removed. There is **no public endpoint** for this on purpose:
it is a manual, documented procedure.

**Diagnosis:** find every row that carries the address before touching
anything, so you can confirm the deletion afterwards:

```sh
docker exec -i nyctaxi-postgres psql -U nyctaxi -d nyctaxi <<'SQL'
SELECT id, email, name, marketing_consent FROM participants WHERE email = '<address>';
SELECT id FROM waitlist WHERE email = '<address>';
SQL
```

**Fix:**

```sql
BEGIN;
UPDATE participants
   SET email = NULL, name = NULL, marketing_consent = FALSE
 WHERE email = '<address>';
DELETE FROM waitlist WHERE email = '<address>';
COMMIT;
```

Then re-run the first query and confirm both are empty. Answer the person
within a reasonable period (§9.1 sets 30 days as the target).

**Notes that matter:**

- **Experiments and decisions stay.** They are already anonymous once the
  participant row no longer points at anyone, and §9.1 keeps them for the
  value of the aggregate.
- **`ip_hash` is not PII we can act on** — it is SHA-256 of a salted IP and
  the salt is a secret; do not try to "delete by IP".
- **Backups still contain the address** until they age out. Tell the requester
  honestly: copies expire after 28 days (§8.5), which is why `/backups` is
  mode 700 and retention is enforced.

**Prevention:** nothing to prevent — this is the designed path. Keep the
privacy notice's contact address working.

---

## Incident: rotate `API_INTERNAL_KEY`

**Symptom:** planned maintenance, or a suspected leak (the key appears in a
log, a gist, a screenshot). Every API endpoint answers **403 without it** (§2.4),
so a botched rotation takes the whole product down.

**Diagnosis:** before rotating, confirm who actually holds the key. It is read
by exactly three places: the API (checks it), the app (sends it) and `share/`
(sends it). `grep` the tracked tree to be sure it was never committed:

```sh
git grep -n 'API_INTERNAL_KEY' -- ':!*.md' | head
```

**Fix — rotate without downtime:**

1. Generate the new value and put it in `.env` **alongside the old one** is
   not possible (one variable), so do it in two steps instead: update `.env`,
   then restart everything that reads it, in the order *producers last*:

   ```sh
   printf 'API_INTERNAL_KEY=%s\n' "$(openssl rand -base64 32)" >> .env
   # (edit .env properly: replace, do not append two keys)
   docker compose -f docker-compose.prod.yml up -d --force-recreate api share shinyproxy
   ```

   ShinyProxy interpolates `${API_INTERNAL_KEY}` into each Shiny container at
   creation time, so **containers already running keep the old key**. Either
   accept that they die naturally, or restart ShinyProxy afterwards so it
   re-reads the file (§8.3).

2. Verify, from outside and from inside:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' https://nyctaxiapp.angelfeliz.com/api/health
   # must be 404 -- there is no route to the API through the edge (§1.0)
   docker exec nyctaxi-share wget -qO- http://api:8000/health
   # must be 200 -- share reaches the API over the private network
   ```

3. Only then delete the old value anywhere else it was copied (CI secret,
   a colleague's `.env`).

**Prevention:** the key lives only in `.env` and in the GitHub Actions secret;
it is never an argument on a command line (that lands in `ps`) and never in
the repository.

---

## Incident: ShinyProxy does not deliver `X-Client-IP`

**Symptom:** the API logs rate limits or experiment creations attributed to a
single bucket, or `test-shiny`'s phase-4 assertion fails in production. The
per-IP rate limits (3 experiments/day, 5 waitlist/day, §5.4) either never trip
or trip for everyone at once, because without a real address every visitor
hashes to the same `unknown` value.

**Diagnosis:** ask the API what it received. `X-Client-IP` is only accepted
together with a valid `X-Internal-Key`, so this needs the key:

```sh
KEY=$(grep -E '^API_INTERNAL_KEY=' .env | cut -d= -f2-)
docker exec nyctaxi-share wget -qO- --header "X-Internal-Key: $KEY" \
  http://api:8000/health >/dev/null   # connectivity first

curl -s -o /dev/null -w '%{http_code}\n' https://nyctaxiapp.angelfeliz.com/api/health
# 404 = the edge really has no route to the API (expected)
```

Then check the chain hop by hop. The header must be set at **every** hop:

1. **Cloudflare → Nginx**: `CF-Connecting-IP`, and Nginx must only trust it
   from Cloudflare's ranges (`infra/nginx/snippets/cloudflare-real-ip.conf`).
   If `set_real_ip_from` is wrong, `$http_cf_connecting_ip` is spoofable and
   `X-Client-IP` becomes attacker-controlled.
2. **Nginx → ShinyProxy**: `proxy_set_header X-Client-IP $http_cf_connecting_ip;`
   in both `location /` and `location /share/`.
3. **Shiny → API**: the app reads `session$request$HTTP_X_CLIENT_IP` and
   re-sends it on every call (`app/R/state.R::client_ip()`).

Debug at the edge — a request that comes back with an empty header localises
the break immediately:

```sh
curl -sI https://nyctaxiapp.angelfeliz.com/ | grep -iE '^(server|cf-|x-)'
```

**Fix:** correct the hop that is missing the header and reload Nginx
(`docker exec nyctaxi-nginx nginx -s reload`); ShinyProxy and Shiny need a
restart only if their config changed.

**Prevention:** the phase-4 flow test asserts the header survives into the
container, and §4 describes a **Plan B** (§5.4) if ShinyProxy ever stops
passing it through: `GET /share/client-token` issues an HMAC of the IP that
the browser hands back with `Shiny.setInputValue`. Implementing it is an
explicit fallback, not something to guess at mid-incident — see ADR-016.

---

## Incident: the public monitor is green but the API is dead

**Symptom:** the uptime monitor shows the site up, and every visitor gets an
error the moment they press *Validate*.

**Diagnosis:** the monitor of section 8.1 watches
`https://nyctaxiapp.angelfeliz.com/`, which is ShinyProxy's landing page -- and
that page does not depend on the API. A dead database, a failed model load or
a wedged API leave it green. That gap is why `health_check.sh` exists: it
probes `/health` on api and share, `pg_isready` and `redis-cli ping` from the
host, where those addresses are reachable.

```sh
./infra/scripts/health_check.sh; echo "exit=$?"
tail -20 /var/log/nyctaxi-health.log
```

`/health` answers **503** when the database or any of the models is missing,
which is deliberate: it is the difference between "the API is running" and
"the product works".

**Fix:** restore whichever of the four failed, then
`./infra/scripts/health_check.sh` must exit 0.

**Prevention:** the hourly cron. A green run clears the alert cooldown, so the
next incident mails immediately instead of waiting six hours.

---

## Incident: the API is up but every day stays in `setup`

**Symptom:** `POST /experiments` answers 201 and `GET
/experiments/{id}/state` keeps returning `status: setup` with `model_progress`
stuck at 0, until the 120 s guard abandons the row and `/state` starts
answering 503.

**Diagnosis:** the trajectory computation runs in a `fork()`ed child (§4.1) and
`libgomp` reads `OMP_NUM_THREADS` **when R starts**. If R started without it,
the child inherits an already-built OpenMP pool and blocks in `futex_wait`
with 0% CPU — it is not slow, it is wedged:

```sh
docker exec nyctaxi-api sh -c 'echo "OMP_NUM_THREADS=$OMP_NUM_THREADS"'
docker stats --no-stream nyctaxi-api     # look for 0% CPU with a live process
docker exec nyctaxi-api sh -c 'ps -eo pid,stat,comm | head'
```

**Fix:**

```sh
docker compose -f docker-compose.prod.yml up -d --force-recreate api
```

`api/plumber.R` prints a WARNING at startup when the variable is missing, and
`test-experiments-async.R` skips its fork test in that case — so grep the log
first:

```sh
docker logs nyctaxi-api 2>&1 | grep -i -E 'OMP|WARNING'
```

**Prevention:** the variable is exported by `api/default.dev.nix`,
`api/default.prod.nix` **and** the Dockerfile stage, and `Sys.setenv()` inside
R is explicitly *not* a fix (libgomp is already loaded by then). Never start
the API with a bare `Rscript api/plumber.R` outside those shells.

---

## Incident: `share/` answers 503

**Symptom:** the share page shows "The result is not available right now." or
the card does not render.

**Diagnosis:** `share/` has no credentials by design (§5.10), so a 503 is
always one of two things — it cannot reach the API, or the API cannot reach
its own data:

```sh
docker logs nyctaxi-share 2>&1 | tail -50
docker exec nyctaxi-share wget -qO- http://api:8000/health   # connectivity
docker exec nyctaxi-api wget -qO- http://127.0.0.1:8000/health
docker exec nyctaxi-redis redis-cli ping
```

Also check the environment: `TAXI_API_URL` must be `http://api:8000` on the
Docker network (it is `http://127.0.0.1:8000` when you run the service by hand
outside compose), and `REDIS_HOST` must be `redis`.

**Fix:** restart whichever hop is broken. If only Redis is down, the card
still renders — `share/` fails open and simply does not count the view or the
render tally (§5.10, ADR-0010); a missing counter is not an incident.

**Prevention:** `depends_on` with `condition: service_healthy` in
`docker-compose.prod.yml`, and the fact that `share/` never holds Postgres
credentials means a database incident cannot take the card down with it.

---

## Incident: the UI freezes mid-day under concurrent users

**Symptom:** a visitor accepts a trip, the clock never moves, and the same
offer stays on screen until they reload. Under the load run it looked like
failed sessions: `POST /decisions` answered 200 (the decision was stored) but
the browser had given up first, and nothing on screen changed again.

**Diagnosis:** plumber2 serves **one request at a time**, so with several
users the queue *is* the latency. Measured at profile 10 (the ceiling — see
below): `/decisions` up to 25 s, `/state` up to 32 s, and **287 of 603**
requests in one run crossed the 15 s client timeout the UI used to carry
(`api_request()` in `app/R/api_client.R`). A timed-out POST is still stored
server-side, the screen keeps the offer it already had, and `in_progress`
days had no `/state` poll to notice — a dead end, not a slowness:

```sh
# On the dev box: durations from the section 11 log of a running load test.
grep '"duration_ms"' "$LOAD_OUT/api.log" | grep -o '"duration_ms":[0-9]*' \
  | cut -d: -f2 | sort -n | tail
```

**Fix:** the client timeout is **45 s** (3× the worst observed round-trip;
nothing in the measured run exceeded it), and the recovery that makes the
timeout survivable: a failed decision arms `estado$resync`, `app.R` polls
`GET /state` once a second until one answer lands, and `finish_can_invoke()`
keeps a `/finish` retry from double-posting into a 409. Both are unit-tested
(`test-utils.R`, `test-state.R`).

**Prevention:** `app/dev/load_test.sh 1 10` before any release that touches
the API's concurrency or the client's timeouts. It is not in CI (§10's
divergence: CI has no models or dataset, so its p95 would measure a stand-in)
— it runs on the dev box or the VM.

### Capacity: ten users is the ceiling, twelve are not

The phase 8 numbers (2026-10-09, 8-core/16 GB host, profiles 1 and 10):
median day **110 s** with one user and **4281 s** with ten (the target is
≤ 720 s), p95 `/sensitivity` 1.98 s → 19.6 s, API RSS pinned at ~1143 MB,
host `MemAvailable` bottoming at **1978 MB**. §1099 allows raising
`max-total-instances` to 12 only with ≥ 2 GB of headroom *and* acceptable
latency; neither holds. Note the measurement host also runs the ten Chromiums
production does not, so the memory floor there is pessimistic — the latency
is not, and it alone settles it. If the queue ever needs to shrink, the lever
is more API processes behind one address (plumber2 will not go concurrent),
not a bigger `max-total-instances`.

---

## Manual checks that are deliberately not in CI

Section 10 excludes `pa11y` and visual regression from CI and asks for a
mobile checklist by hand; section 12 asks for the contrast to be signed off
against WebAIM. What is already automated is listed first, so nobody
re-does it.

Already checked on every run, in `app/tests/testthat/test-accessibility.R`:

- `prefers-reduced-motion` is honoured (one rule collapses every duration).
- Both `girafe()` charts carry `role="img"` and an `aria-label` that is a
  sentence, not the chart's title.
- **Every text pair in both themes clears WCAG AA (4.5:1)**, computed from
  `taxi_palette()` — including `--taxi-muted-fg`, which exists precisely
  because the old single grey reached only 4.44:1 on the light surface and
  3.41:1 on the dark one — and the `link`/`link_hover` tokens, which pa11y
  caught at 4.24:1 when anchors were painted with the brand primary.
- The pending clock prints its hours as text, so the green/amber/red bar is
  never the only signal (§3.11).

### How to run the three checks (phase 8, last run 2026-10-09)

**1. pa11y** — never in CI (§10: no models there). Against a running stack
(`dev/e2e.sh` in hold mode, or the app with the API up), from `app/`:

```sh
npx -y pa11y@10 http://127.0.0.1:3839/ --config dev/pa11y.json -r json
```

The config is versioned in `app/dev/pa11y.json`. Two knobs in it are
load-bearing, not preferences:

- `levelCapWhenNeedsReview: "notice"` — axe's `incomplete` array ("the
  background could not be determined") is reported by pa11y as errors by
  default. Those are *review* items, and the review is this checklist's
  job. **Last run: 0 errors, 26 warnings**, all of them either Shiny
  landmarks (`region`, `landmark-one-main` — a single-page app has no
  `<main>` per panel) or HTMLCS notices on transparent overlays. The eight
  needs-review contrast items were read by hand: five are Leaflet's own
  controls (zoom/attribution — excluded via `hideElements` now), three
  measured `#35393e` on `#f6f7f9` = 11:1.
- The `chromeLaunchConfig` path points at the Chrome that puppeteer
  installed inside the dev image; `--no-sandbox` because the image runs as
  root. On a host with your own Chrome, point `executablePath` at it.

**2. WebAIM contrast sign-off** (§12) — the tool, not just our formula:

```text
https://webaim.org/resources/contrastchecker/?fcolor=6657ec&bcolor=f6f7f9&api
```

Swap `fcolor`/`bcolor` for each pair (`&api` returns JSON). **Signed off
2026-10-09**, all AA pass: light link `#6657ec`/surface 4.73 · light
link/bg 5.07 · muted `#5b6678`/surface 5.41 · body `#1f2328`/surface
14.70 · dark link `#8b7dff`/dark-surface 5.01 · dark link/dark-bg 5.51.
Our test and WebAIM agree to two decimals — that agreement is the point
of the check.

**3. Mobile checklist (390px)** — headless or a device:

```text
viewport 390x844, hasTouch, (pointer: coarse); then Setup → validate →
Start The Day → resume modal → Trips, accept once, and read:
```

- No horizontal overflow on Setup, Trips **and** `/privacy.html`.
- `.kbd-footer` computes to `display: none` (§6.5 hides hints on touch).
- Every tap target ≥ 44px: accept/reject (measured 160×78), validate
  (258×47), the three checkbox *labels* (300×44 — the label is the target,
  not the 19×19 input), and the navbar toggle (44×44 since `styles.css`
  gained it under `@media (pointer: coarse)`).
- The dark-mode toggle sits **outside** `<ul role="tablist">` (moved by
  `www/js/a11y.js`; without JS it stays inside and pa11y reports one
  `aria-required-children` instead of a broken control).

Still genuinely manual: `/share` on a real phone and the LinkedIn in-app
browser — no headless tool replicates their webviews.

### What these checks caught (2026-10-09)

Worth knowing because each looks like a test problem and was a product
problem:

- **`www/styles.css` was never loaded.** The `<link>` was lost in the
  phase-5 migration from `page_fluid` to `page_navbar`; the sheet has been
  served (200) and ignored since. Every rule in it — reduced-motion, the
  44px tap targets, the hidden keyboard hints on touch, the warning red —
  was dead code. The mobile checklist (a visible `kbd-footer` under
  `pointer: coarse`) is what found it.
- **Anchor contrast 4.24:1**: links inherited `$link-color = $primary`,
  which clears AA on `bg` but not on the `surface` most of them sit on.
- **pa11y's first run: 30 errors** (HTMLCS on selectize's hidden selects,
  the toggle inside the tablist, empty heading, nameless icon button) —
  all four fixed in the product, not silenced in config; see the CHANGELOG
  entries for each.

---

## Routine checks

Not incidents — things worth doing on a quiet day:

```sh
# The four things the product cannot work without. Cron runs this hourly and
# mails when one fails (section 11: "alertas minimas" -- no Prometheus here).
./infra/scripts/health_check.sh; echo "exit=$?"

# Exposure: only nginx may publish a port (§9.3, and the deploy smoke test).
docker ps --format '{{.Names}} {{.Ports}}'

# Backups exist, are recent, and restore.
ls -lah /backups | tail
./infra/scripts/restore_test.sh

# Disk trend, not just today's number.
tail -20 /var/log/nyctaxi-disk.log

# Stack health.
docker compose -f docker-compose.prod.yml ps
```
