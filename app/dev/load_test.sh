#!/usr/bin/env bash
# N concurrent browser sessions against ONE app, and the three numbers
# section 8 asks for (server memory, p95 of /sensitivity, the median day).
#
#   ./dev/load_test.sh                # profile 10, both strategies
#   ./dev/load_test.sh 1 10 20        # the three profiles of section 8
#   STRATEGY=accept-all ./dev/load_test.sh 20
#   LOAD_STRICT=1 ./dev/load_test.sh 10    # performance targets fail the run
#
# Run it from a nix-shell that has the app's dependencies (`nix-shell
# app/default.dev.nix`), inside the development image -- Cypress and node come
# from the image (layer 11), R and its packages from the shell. It needs the
# same things the browser suite needs: Postgres, Redis and mailpit up, and
# the release assets mounted (CI's recipe mounts them at /models and /data).
#
# What is measured, and from where (ADR-0012): "resources per user" is the
# SERVER's, because N Chromiums would measure the driver. So the browsers only
# play days; this script samples the app and API processes while they run,
# reads the section 11 log for p95 of /sensitivity -- the latency the API
# itself measured under that load, not a probe's -- and asks Postgres for the
# median day. A session's own assertions live in cypress/e2e/load.cy.js and
# dev/load_sessions.js: each one finished the day it started, its KPIs are
# its own clicks, and it followed the strategy it was given.
#
# Not in CI: a divergence with section 10, recorded in CHANGELOG.md. CI has
# no models and no dataset, so a p95 of /sensitivity measured there would be
# a number about the thing standing in for the service.
#
# Exit code 0 = every session played its own day and followed its strategy.
# The performance targets of section 8 are reported PASS/FAIL and only change
# the exit code under LOAD_STRICT=1: a slow box is a finding, a crossed day
# is a bug.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(cd .. && pwd)"
PROFILES=("$@")
[ ${#PROFILES[@]} -gt 0 ] || PROFILES=(10)

STRATEGY="${STRATEGY:-both}"          # both | accept-all | model-only
PROXY_BASE_PORT="${PROXY_BASE_PORT:-4100}"
APP_PORT="${APP_PORT:-3838}"
API_PORT="${API_PORT:-8000}"
export APP_PORT API_PORT
STAGGER_S="${STAGGER_S:-1}"
# 4.6 gives a day 120 s to leave `setup`; N sessions create their days at the
# same instant and the forked children share the cores, so a load run raises
# the knob instead of racing it. Reported in the run's own output.
SETUP_TIMEOUT_S="${SETUP_TIMEOUT_S:-600}"
DAY_TARGET_S="${DAY_TARGET_S:-720}"   # section 8: median day <= 12 min
LOAD_STRICT="${LOAD_STRICT:-0}"
# TEST-NET-3 again: session i gets 203.0.113.(100+i), because 5.4 allows 3
# experiments per IP per day and every session of the run creates one.
IP_BASE="${IP_BASE:-100}"

export CYPRESS_CACHE_FOLDER="${CYPRESS_CACHE_FOLDER:-/opt/cypress-cache}"
# Same prepend as e2e.sh: nix-shell rewrites PATH from its buildInputs, and
# Cypress and node come from the image's own ENV (Dockerfile layer 11).
PATH="/opt/npm/bin:/nix/profiles/node/bin:${PATH}"
export PATH
export API_INTERNAL_KEY="${API_INTERNAL_KEY:-load-test-internal-key}"
export IP_HASH_SALT="${IP_HASH_SALT:-load-test-salt}"
export SETUP_TIMEOUT_S

# The same two helpers e2e.sh uses, for the one query that runs outside the
# API: the median day. Inside the development container the compose has
# already mounted the assets at /models and /data; on a host, .env's
# MODELS_DIR/DATA_DIR are the same directories and TAXI_* is what the API
# reads (api/R/ml_load_model.R, api/R/data_trips.R).
env_from_dotenv() {
  local key=$1 value
  [ -n "${!key:-}" ] && return 0
  [ -f "$ROOT/.env" ] || return 0
  value=$(grep -m1 "^${key}=" "$ROOT/.env" | cut -d= -f2-) || true
  [ -n "$value" ] && export "$key=$value"
}
# Same call as e2e.sh: .env describes the compose network ("postgres",
# "redis"), while this script runs outside it, where both names resolve
# nowhere and the loopback is where compose publishes them.
resolvable_or() {
  if [ -n "$1" ] && getent hosts "$1" >/dev/null 2>&1; then
    printf '%s' "$1"
  else
    printf '%s' "$2"
  fi
}
for key in POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
           REDIS_PORT; do
  env_from_dotenv "$key"
done
POSTGRES_HOST="$(resolvable_or "${POSTGRES_HOST:-postgres}" 127.0.0.1)"
export POSTGRES_HOST
REDIS_HOST="$(resolvable_or "${REDIS_HOST:-redis}" 127.0.0.1)"
export REDIS_HOST
if [ -z "${TAXI_MODELS_DIR:-}" ] && [ ! -d /models ]; then
  env_from_dotenv MODELS_DIR
  [ -d "${MODELS_DIR:-/nonexistent}" ] && export TAXI_MODELS_DIR="$MODELS_DIR"
fi
if [ -z "${TAXI_DATA_DIR:-}" ] && [ ! -d /data ]; then
  env_from_dotenv DATA_DIR
  [ -d "${DATA_DIR:-/nonexistent}" ] && export TAXI_DATA_DIR="$DATA_DIR"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${LOAD_OUT_DIR:-dev/load/$stamp}"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.md"
echo "load run $stamp" | tee "$REPORT"
echo "profiles: ${PROFILES[*]} | strategy: $STRATEGY | out: $OUT_DIR" | tee -a "$REPORT"

hold_pid=""
sampler_pid=""
proxy_pids=()
declare -a PROFILE_FAILURES=()

teardown() {
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null || true
  local pid
  for pid in ${proxy_pids[@]+"${proxy_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  [ -n "$hold_pid" ] && kill "$hold_pid" 2>/dev/null || true
}
trap teardown EXIT

# ---- the server sampler ----------------------------------------------------
# /proc, not ps: one process tree, two numbers, every two seconds, and no
# dependency on procps being in the image.
#
# A tree, not a pid: the READY line hands over the nix-shell that STARTED
# each service, and that wrapper idles at 5 MB while R does the work -- the
# first version sampled exactly that and reported "api peak RSS 5 MB, peak
# CPU 0%" for a run that was computing grids. So each tick walks the subtree
# (R, its mirai workers, the forked trajectory children) and sums it. CPU is
# the delta of utime+stime between ticks -- ps's %cpu is a lifetime average,
# which on a run this short reports the idle start as the whole story.
ticks_per_s=$(getconf CLK_TCK 2>/dev/null || echo 100)

# One scan of /proc per tick, kept as parallel arrays for the walk below.
pairs_pid=()
pairs_ppid=()
collect_pairs() {
  pairs_pid=()
  pairs_ppid=()
  local f content p pp
  for f in /proc/[0-9]*/stat; do
    # cat, not $(<"$f"): a process can die between the glob and the read, and
    # the command-substitution shortcut prints bash's own error *during*
    # the expansion, where the trailing 2>/dev/null no longer catches it --
    # one leaked "/proc/794/stat: No such file" per tick, in the run's log.
    content=$(cat "$f" 2>/dev/null) || continue
    content=${content#*) }          # drop "pid (comm)" -- comm may hold spaces
    set -- $content
    pp=${2:-0}                      # state is $1, ppid is $2
    p=${f#/proc/}; p=${p%/stat}
    pairs_pid+=("$p")
    pairs_ppid+=("$pp")
  done
}

subtree() { # $1 = root pid -> the pids of its subtree, space separated
  collect_pairs
  # Every list keeps a space at both ends so the case patterns below match
  # WHOLE pids: without them " 1 " matched the 1 inside 353360 and the walk
  # swallowed every process on the machine (measured: 242 pids for a tree
  # that had 5).
  local seen=" $1 " frontier=" $1 " next i
  while [ -n "$frontier" ]; do
    next=""
    for i in "${!pairs_pid[@]}"; do
      case "$frontier" in
        *" ${pairs_ppid[$i]} "*) ;;
        *) continue ;;
      esac
      case "$seen" in
        *" ${pairs_pid[$i]} "*) ;;
        *) next="$next${pairs_pid[$i]} " ; seen="$seen${pairs_pid[$i]} " ;;
      esac
    done
    printf '%s' "$frontier"
    frontier="$next"
  done
}

cpu_ticks() { # $1 = pid -> utime+stime, empty when the process is gone
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  stat=${stat#*) }
  set -- $stat
  echo $(( ${12:-0} + ${13:-0} ))    # utime is field 14, stime 15 (1-based)
}

rss_kb() { # $1 = pid -> VmRSS in kB
  awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null
}

mem_available_kb() {
  awk '/^MemAvailable:/ {print $2}' /proc/meminfo
}

start_sampler() { # $1 = app pid, $2 = api pid, $3 = csv path
  local app_root=$1 api_root=$2 csv=$3
  (
    echo "seconds,app_rss_kb,app_cpu_pct,api_rss_kb,api_cpu_pct,mem_available_kb"
    local t0 app_prev=0 api_prev=0 prev_t="" t pid rss k
    local app_rss api_rss app_tree api_tree acpu pcpu aticks pticks span
    t0=$(date +%s)
    while :; do
      t=$(( $(date +%s) - t0 ))
      app_tree=$(subtree "$app_root")
      api_tree=$(subtree "$api_root")

      app_rss=0; aticks=0
      for pid in $app_tree; do
        rss=$(rss_kb "$pid"); app_rss=$(( app_rss + ${rss:-0} ))
        k=$(cpu_ticks "$pid"); aticks=$(( aticks + ${k:-0} ))
      done
      api_rss=0; pticks=0
      for pid in $api_tree; do
        rss=$(rss_kb "$pid"); api_rss=$(( api_rss + ${rss:-0} ))
        k=$(cpu_ticks "$pid"); pticks=$(( pticks + ${k:-0} ))
      done

      acpu=0; pcpu=0
      if [ -n "$prev_t" ]; then
        span=$(( t - prev_t ))
        if [ "$span" -gt 0 ]; then
          acpu=$(( (aticks - app_prev) * 100 / ticks_per_s / span ))
          pcpu=$(( (pticks - api_prev) * 100 / ticks_per_s / span ))
          [ "$acpu" -lt 0 ] && acpu=0
          [ "$pcpu" -lt 0 ] && pcpu=0
        fi
      fi
      app_prev=$aticks; api_prev=$pticks; prev_t=$t
      echo "$t,$app_rss,$acpu,$api_rss,$pcpu,$(mem_available_kb)"
      sleep 2
    done
  ) > "$csv" &
  sampler_pid=$!
}

# ---- one profile -----------------------------------------------------------
run_profile() {
  local users=$1
  local out="$OUT_DIR/profile-$users"
  mkdir -p "$out"
  local results="$out/sessions.jsonl"
  : > "$results"
  local profile_failed=0

  echo | tee -a "$REPORT"
  echo "## profile $users — $(date -u +%H:%M:%S) UTC" | tee -a "$REPORT"

  # 1. The stack, in hold mode: the same e2e.sh the browser suite uses, just
  #    kept alive instead of running one spec against it. The wait budgets go
  #    up with it: a cold nix-shell unpacks its pin tarball before R even
  #    starts, and the run died once inside e2e.sh's own 90 s API budget with
  #    the API seconds from listening.
  E2E_HOLD=1 E2E_LOG_DIR="$out" \
    API_WAIT_S="${API_WAIT_S:-300}" \
    SHARE_WAIT_S="${SHARE_WAIT_S:-180}" \
    APP_WAIT_S="${APP_WAIT_S:-120}" \
    ./dev/e2e.sh > "$out/e2e.log" 2>&1 &
  hold_pid=$!
  local ready=""
  local i
  for i in $(seq 1 300); do
    ready=$(grep -m1 '^E2E_READY ' "$out/e2e.log" 2>/dev/null || true)
    [ -n "$ready" ] && break
    kill -0 "$hold_pid" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$ready" ]; then
    echo "FAIL: the stack never came up (see $out/e2e.log)" | tee -a "$REPORT"
    tail -20 "$out/e2e.log" | tee -a "$REPORT" >&2 || true
    kill "$hold_pid" 2>/dev/null || true
    wait "$hold_pid" 2>/dev/null || true
    hold_pid=""
    return 1
  fi
  local app_pid api_pid log_dir
  app_pid=$(sed -n 's/.*app_pid=\([0-9]*\).*/\1/p' <<<"$ready")
  api_pid=$(sed -n 's/.*api_pid=\([0-9]*\).*/\1/p' <<<"$ready")
  log_dir=$(sed -n 's/.*log_dir=\([^ ]*\).*/\1/p' <<<"$ready")
  # An empty pid means e2e.sh REUSED a service that was already answering --
  # an orphan from a previous profile, or one the developer left running.
  # Sampling it would report "api tree peak RSS 0" for the whole profile and
  # its api.log (the section 11 log p95 comes from) would not exist, so stop
  # here and say which port is occupied instead.
  if [ -z "$app_pid" ] || [ -z "$api_pid" ]; then
    echo "FAIL: the stack was not started fresh (app_pid='$app_pid' api_pid='$api_pid')." | tee -a "$REPORT"
    echo "      Something is already answering on :${API_PORT}/:${APP_PORT} -- stop it and re-run." | tee -a "$REPORT"
    kill "$hold_pid" 2>/dev/null || true
    wait "$hold_pid" 2>/dev/null || true
    hold_pid=""
    return 1
  fi
  echo "stack up: app=$app_pid api=$api_pid logs=$log_dir" | tee -a "$REPORT"

  # 2. One flush, before any session: every session has its own IP, but a
  #    previous run the same day would have counted against the same ones.
  if ! node cypress/redis_client.js FLUSHDB > "$out/redis.log" 2>&1; then
    echo "FAIL: Redis did not accept FLUSHDB (see $out/redis.log)" | tee -a "$REPORT"
    teardown; hold_pid=""; return 1
  fi

  # 3. One proxy per session: the address the API sees (5.4) is assigned
  #    here, one per browser, so the limiter counts each session as itself.
  proxy_pids=()
  local ports=() ips=()
  for i in $(seq 1 "$users"); do
    local port=$((PROXY_BASE_PORT + i)) ip="203.0.113.$((IP_BASE + i))"
    PROXY_PORT=$port PROXY_CLIENT_IP=$ip PROXY_UPSTREAM_PORT=$APP_PORT \
      node dev/e2e-proxy.js > "$out/proxy-$i.log" 2>&1 &
    proxy_pids+=($!)
    ports+=("$port")
    ips+=("$ip")
  done
  sleep 1

  # 4. The sampler, while everything else runs.
  local csv="$out/resources.csv"
  start_sampler "$app_pid" "$api_pid" "$csv"

  # 5. The sessions themselves, staggered by STAGGER_S so 20 Chromiums do not
  #    all race the app's first paint at the same millisecond. They run
  #    concurrently from there on: that concurrency is the thing measured.
  local started_at finished_at
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local cypress_pids=() failed=0
  for i in $(seq 1 "$users"); do
    local strat
    if [ "$STRATEGY" = "both" ]; then
      if [ $((i % 2)) -eq 1 ]; then strat=accept-all; else strat=model-only; fi
    else
      strat=$STRATEGY
    fi
    (
      # The comment goes BEFORE the assignments, never between them and the
      # command: a line continuation followed by `# comment` ends the logical
      # line, the prefixes turn into bare shell variables and cypress runs
      # without them -- no LOAD_RESULTS_FILE, the default baseUrl, the default
      # strategy. That exact mistake cost a whole 1/10 profile run.
      #
      # pageLoadTimeout and responseTimeout up from 60 s / 30 s: N sessions
      # opening at once serialize on one R process, and at profile 10 the last
      # arrivals were still waiting for a response 30 s in (ESOCKETTIMEDOUT on
      # the visit -- 30 s is responseTimeout's default; there is no
      # connectionTimeout in Cypress 15, which only prints the option as
      # invalid). The ramp is the thing being measured; the browser's default
      # patience is not.
      CYPRESS_BASE_URL="http://127.0.0.1:${ports[$((i - 1))]}" \
      CYPRESS_STRATEGY="$strat" \
      CYPRESS_LOAD_ID="$i" \
      CYPRESS_CLIENT_IP="${ips[$((i - 1))]}" \
      LOAD_RESULTS_FILE="$results" \
      /opt/npm/bin/cypress run \
        --spec cypress/load/load.cy.js \
        --config "specPattern=cypress/load/**/*.cy.js,pageLoadTimeout=180000,responseTimeout=180000" \
        > "$out/session-$i.log" 2>&1
    ) &
    cypress_pids+=($!)
    echo "session $i ($strat) via :${ports[$((i - 1))]} as ${ips[$((i - 1))]}"
    sleep "$STAGGER_S"
  done
  for i in $(seq 0 $((users - 1))); do
    if ! wait "${cypress_pids[$i]}"; then
      echo "FAIL: session $((i + 1)) exited non-zero (see $out/session-$((i + 1)).log)" | tee -a "$REPORT"
      failed=1
    fi
  done
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 6. Take the stack down before reading anything: the numbers belong to the
  #    run, not to what the next one does.
  kill "$sampler_pid" 2>/dev/null || true
  sampler_pid=""
  teardown
  wait "$hold_pid" 2>/dev/null || true
  hold_pid=""
  proxy_pids=()

  # 7. The session assertions (cross-talk, strategies) in their own file.
  if ! node dev/load_sessions.js "$results" "$users" "$STRATEGY" \
      | tee -a "$REPORT"; then
    failed=1
  fi

  # 8. p95 of /sensitivity, from the API's own section 11 log: the latency it
  #    measured for the requests these sessions made, under this load.
  local api_log="$log_dir/api.log"
  local sens_stats="n=0"
  if [ -f "$api_log" ]; then
    local durations
    durations=$(grep '"path":"/sensitivity"' "$api_log" \
      | grep -o '"duration_ms":[0-9]*' | cut -d: -f2 | sort -n || true)
    if [ -n "$durations" ]; then
      sens_stats=$(printf '%s\n' "$durations" | awk '
        { a[NR] = $1 }
        END {
          n = NR
          p95i = int(0.95 * n + 0.999999); if (p95i < 1) p95i = 1; if (p95i > n) p95i = n
          med = a[int((n + 1) / 2)]
          printf "n=%d median_ms=%.0f p95_ms=%.0f max_ms=%.0f\n", n, med, a[p95i], a[n]
        }')
    fi
    local bad_sens
    bad_sens=$(grep '"path":"/sensitivity"' "$api_log" \
      | grep -vc '"status":200' || true)
    echo "/sensitivity: $sens_stats (non-200: $bad_sens)" | tee -a "$REPORT"
    local statuses
    statuses=$(grep -o '"status":[0-9]*' "$api_log" | sort | uniq -c \
      | tr '\n' ' ' || true)
    echo "API responses by status: $statuses" | tee -a "$REPORT"
  else
    echo "WARN: no api.log at $api_log; p95 of /sensitivity unavailable" | tee -a "$REPORT"
  fi

  # 9. Server memory and CPU, from the sampler's own CSV.
  if [ -f "$csv" ] && [ "$(wc -l < "$csv")" -gt 1 ]; then
    awk -F, 'NR > 1 {
        if ($2 > app_rss) app_rss = $2
        if ($4 > api_rss) api_rss = $4
        if ($3 > app_cpu) app_cpu = $3
        if ($5 > api_cpu) api_cpu = $5
        if (min_mem == 0 || $6 < min_mem) min_mem = $6
        n++
      }
      END {
        printf "server: app tree peak RSS %.0f MB, peak CPU %.0f%% | api tree peak RSS %.0f MB, peak CPU %.0f%% | host MemAvailable min %.0f MB (%d samples)\n",
          app_rss / 1024, app_cpu, api_rss / 1024, api_cpu, min_mem / 1024, n
      }' "$csv" | tee -a "$REPORT"
  else
    echo "WARN: the sampler wrote no samples" | tee -a "$REPORT"
  fi

  # 10. The median day, from Postgres (section 8: "the median day is SQL").
  #     The window is the run's, so the number is about these sessions.
  local median_line=""
  if median_line=$(
    (cd "$ROOT" && LOAD_START="$started_at" LOAD_END="$finished_at" \
      nix-shell api/default.dev.nix --run "Rscript app/dev/median_day.R") \
      2> "$out/median_day.err"
  ); then
    echo "median day (SQL): $median_line" | tee -a "$REPORT"
  else
    echo "WARN: the median day query failed (see $out/median_day.err)" | tee -a "$REPORT"
  fi
  # Section 8's target, checked against the SQL number when there is one.
  if [[ "$median_line" == *median_s=* ]]; then
    local median_s
    median_s=$(sed -n 's/.*median_s=\([0-9.]*\).*/\1/p' <<<"$median_line")
    if [ -n "$median_s" ] && [ "$median_s" != "NA" ]; then
      local met=no
      if awk -v m="$median_s" -v t="$DAY_TARGET_S" 'BEGIN { exit !(m <= t) }'; then
        met=yes
      fi
      echo "median day ${median_s} s vs target ${DAY_TARGET_S} s: $met" | tee -a "$REPORT"
      if [ "$met" = "no" ] && [ "$LOAD_STRICT" = "1" ]; then failed=1; fi
    fi
  fi

  if [ "$failed" -ne 0 ]; then
    PROFILE_FAILURES+=("$users")
    echo "profile $users: FAILED" | tee -a "$REPORT"
    return 1
  fi
  echo "profile $users: ok" | tee -a "$REPORT"
  return 0
}

overall=0
for profile in ${PROFILES[@]+"${PROFILES[@]}"}; do
  if ! run_profile "$profile"; then
    overall=1
    # A failed profile must not take the next one down with it: the stack is
    # down (teardown ran), the output directory is per profile.
    hold_pid=""
    sampler_pid=""
    proxy_pids=()
    continue
  fi
done

echo | tee -a "$REPORT"
if [ "$overall" -eq 0 ]; then
  echo "load run ok — report: $REPORT" | tee -a "$REPORT"
else
  echo "load run FAILED (${PROFILE_FAILURES[*]:-see report}) — report: $REPORT" | tee -a "$REPORT"
fi
exit "$overall"
