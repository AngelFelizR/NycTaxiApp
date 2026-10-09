// Read the JSONL the sessions of a load run wrote (task `load_record`) and
// decide whether N sessions played N separate days -- the reliability bar
// chosen for section 8, and the only cross-talk check that means anything
// (6.1.5: no session may read or write another's state).
//
//   node dev/load_sessions.js <sessions.jsonl> <expected> <strategy>
//
// Exits non-zero with one line per broken assertion; the lines are meant to
// survive a shell's grep, so they all start with `assert:`. Also prints the
// per-session table dev/load_test.sh puts in its report: this file is where
// the JSON is read, not the shell -- a shell that parses JSON with sed is a
// shell that will one day parse it wrongly.
const fs = require("fs");

const [, , file, expectedArg, strategyArg] = process.argv;
const expected = Number(expectedArg || 0);
const strategy = strategyArg || "both";

if (!file || !fs.existsSync(file)) {
  process.stderr.write(`assert: no session records at ${file || "(unset)"}\n`);
  process.exit(1);
}

const rows = fs
  .readFileSync(file, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line));

const failures = [];
const check = (condition, message) => {
  if (!condition) failures.push(message);
};

check(
  rows.length === expected,
  `expected ${expected} session records, got ${rows.length}`,
);

const expIds = new Set(rows.map((r) => r.exp_id));
check(
  expIds.size === rows.length,
  `sessions share experiment ids: ${expIds.size} distinct of ${rows.length} (cross-talk)`,
);

// Each session plays from its own address, because 5.4 allows 3 experiments
// per IP per day and dev/load_test.sh starts one proxy per session to give it
// one. A run where two sessions report the same address is a run where one of
// them was let through by the other's counter.
const ips = rows.map((r) => r.client_ip).filter(Boolean);
if (ips.length > 0) {
  check(
    ips.length === rows.length,
    `only ${ips.length} of ${rows.length} sessions reported a client IP`,
  );
  check(
    new Set(ips).size === ips.length,
    `sessions share a client IP: ${new Set(ips).size} distinct of ${ips.length}`,
  );
}

let acceptAllRejectOffers = 0;
let modelOnlyRejected = 0;
const walls = [];

rows.forEach((r) => {
  const who = `session ${r.load_id} (${r.strategy})`;
  check(/^[0-9a-f-]{36}$/.test(r.exp_id || ""), `${who}: bad experiment id ${r.exp_id}`);
  check(r.clicks > 0, `${who}: played no decision`);
  // Same bound as the spec's own assertion: at most, never equality. A click
  // may store nothing -- the run's recovery sends a stale POST and the API
  // answers 409 without storing (measured: 49 clicks, 48 stored, one
  // decision 409). MORE decisions than this session made would be someone
  // else's click landing here, which is what 6.1.5 forbids.
  check(
    r.accepted + r.rejected <= r.clicks,
    `${who}: ${r.accepted}+${r.rejected} KPI decisions for ${r.clicks} clicks`,
  );
  check(Boolean(r.started_at) && Boolean(r.finished_at), `${who}: no start/finish timestamps`);
  check(r.sensitivity === true, `${who}: never drew the what-if grid`);

  if (r.strategy === "accept-all") {
    check(r.rejected === 0, `${who}: rejected ${r.rejected} trips`);
    acceptAllRejectOffers += r.model_reject_offers || 0;
  } else {
    check(
      r.following === 100,
      `${who}: the server counts ${r.following}% following the policy, not 100`,
    );
    modelOnlyRejected += r.rejected || 0;
  }

  if (r.started_at && r.finished_at) {
    walls.push((new Date(r.finished_at) - new Date(r.started_at)) / 1000);
  }
});

if (strategy === "both" && rows.length >= 2) {
  const acceptAll = rows.filter((r) => r.strategy === "accept-all").length;
  const modelOnly = rows.length - acceptAll;
  check(acceptAll > 0 && modelOnly > 0, "STRATEGY=both must run both strategies");
  // The two strategies only mean something if they diverge on this data: the
  // model has to decline some offer. When it declines none, accept-all and
  // model-only play the same day and the run says nothing about either.
  check(
    acceptAllRejectOffers > 0 || modelOnlyRejected > 0,
    "the model declined no offer in this run: the two strategies coincide, rerun",
  );
}

walls.sort((a, b) => a - b);
const medianWall = walls.length ? walls[Math.floor(walls.length / 2)] : NaN;

process.stdout.write("\nsession  strategy     ip             decisions  accepted  rejected  following  wall_s\n");
rows
  .slice()
  .sort((a, b) => Number(a.load_id) - Number(b.load_id))
  .forEach((r) => {
    const wall =
      r.started_at && r.finished_at
        ? Math.round((new Date(r.finished_at) - new Date(r.started_at)) / 1000)
        : "-";
    process.stdout.write(
      `${String(r.load_id).padEnd(8)} ${String(r.strategy).padEnd(12)} ` +
        `${String(r.client_ip || "-").padEnd(14)} ${String(r.clicks).padEnd(10)} ` +
        `${String(r.accepted).padEnd(9)} ${String(r.rejected).padEnd(9)} ` +
        `${String(r.following).padEnd(10)} ${wall}\n`,
    );
  });
process.stdout.write(
  `client median wall clock: ${Number.isFinite(medianWall) ? medianWall.toFixed(1) : "n/a"} s ` +
    `(${rows.length} sessions)\n`,
);

failures.forEach((f) => process.stdout.write(`assert: ${f}\n`));
if (failures.length > 0) {
  process.stdout.write(`${failures.length} assertion(s) failed\n`);
  process.exit(1);
}
process.stdout.write("session assertions passed\n");
