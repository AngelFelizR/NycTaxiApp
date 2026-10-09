// Cypress configuration for the Shiny app (section 10, phase 8).
//
// The app under test is Shiny: it answers over a WebSocket and rewrites its
// own DOM, so `cy.visit()` gets a page that is only half-built. Every spec
// waits for a real selector rather than for "the page loaded", which is what
// the shinytest2 tests did with wait_for_idle() -- the DOM is the only signal
// Cypress has.
//
// `e2e/devServer` is not used: the app is R, so app/dev/e2e.sh starts it (the
// API, share/ and the proxy that carries the client IP) and tears it down
// afterwards. dev/load_test.sh starts the same stack in hold mode and drives
// N of these at once instead of one.
// A plain object, not defineConfig(): Cypress is installed once in the image
// (layer 11) rather than in node_modules, so require("cypress") here would
// fail with "Cannot find module" -- the helper only wraps the object, it does
// not read it.
//
// setupNodeEvents carries the three tasks a spec needs from the server side:
//
//   redis_flush_db    -- resets the rate-limit counters (5.4). The API allows
//                        3 experiments per IP per day, counts every attempt
//                        including the ones that fail validation, and the
//                        browser cannot present a different IP. Each spec that
//                        creates days clears it so the order of the run does
//                        not decide the outcome. The load run does not call
//                        it: every session there has its own IP (see
//                        dev/load_test.sh) and dev/load_test.sh flushes once
//                        before the first one.
//   rate_limit_key    -- reads the counter back under the key the API derives
//                        from sha256(IP_HASH_SALT || ip), which is how a spec
//                        proves which address the API actually saw (13).
//   load_record       -- appends one JSON line per finished load session to
//                        LOAD_RESULTS_FILE, the file dev/load_test.sh reads
//                        back to assert that N sessions played N separate
//                        days. The task must return something: Cypress turns
//                        `undefined` into "you forgot to return a value".
//
// The RESP client itself lives in cypress/redis_client.js, where the load
// script can also run it from the shell (`node cypress/redis_client.js
// FLUSHDB`) instead of speaking the protocol a second time.
const fs = require("fs");
const { redis_command, rate_limit_key_for } = require("./cypress/redis_client");

module.exports = {
  e2e: {
    specPattern: "cypress/e2e/**/*.cy.js",
    // Overridden by CYPRESS_BASE_URL when the port differs.
    baseUrl: "http://127.0.0.1:3839",
    supportFile: "cypress/support/e2e.js",
    // Shiny's own sockets keep Cypress's network idle detection from ever
    // settling; assert on selectors instead of on idleness.
    chromeWebSecurity: false,
    defaultCommandTimeout: 20000,
    pageLoadTimeout: 60000,
    video: false,
    screenshotOnRunFailure: true,
    setupNodeEvents(on) {
      on("task", {
        redis_flush_db() {
          return redis_command(["FLUSHDB"]);
        },
        async rate_limit_key(ip) {
          const key = rate_limit_key_for(ip);
          const counter = await redis_command(["GET", key]);
          return { key, counter: counter === null ? 0 : Number(counter) };
        },
        load_record(entry) {
          const file = process.env.LOAD_RESULTS_FILE;
          if (!file) {
            throw new Error(
              "LOAD_RESULTS_FILE is not set; only dev/load_test.sh runs a load session",
            );
          }
          fs.appendFileSync(file, `${JSON.stringify(entry)}\n`);
          return null;
        },
      });
    },
  },
};
