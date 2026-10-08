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
// afterwards.
// A plain object, not defineConfig(): Cypress is installed once in the image
// (layer 11) rather than in node_modules, so require("cypress") here would
// fail with "Cannot find module 'cypress'" -- the helper only wraps the
// object, it does not read it.
//
// setupNodeEvents carries the two tasks a spec needs from the server side,
// both against Redis:
//
//   redis_flush_db    -- resets the rate-limit counters (5.4). The API allows
//                        3 experiments per IP per day, counts every attempt
//                        including the ones that fail validation, and the
//                        browser cannot present a different IP. Each spec that
//                        creates days clears it so the order of the run does
//                        not decide the outcome.
//   rate_limit_key    -- reads the counter back under the key the API derives
//                        from sha256(IP_HASH_SALT || ip), which is how a spec
//                        proves which address the API actually saw (13).
//
// RESP by hand over a socket: the image has node but no redis client, and
// adding one to keep a dozen lines of protocol out of here is the worse
// trade. The reply parser only handles what those two commands answer --
// status, bulk and nil -- because a parser nobody exercises is a parser that
// lies.
const crypto = require("crypto");
const net = require("net");

const redis_endpoint = () => ({
  host: process.env.REDIS_HOST || "127.0.0.1",
  port: Number(process.env.REDIS_PORT || 6379),
});

const encode = (args) =>
  `*${args.length}\r\n` +
  args.map((a) => `$${Buffer.byteLength(a)}\r\n${a}\r\n`).join("");

// undefined = incomplete, anything else is the answer. Bulk replies are
// length-prefixed, so a reply split across two packets is only complete once
// the declared number of bytes has arrived.
const parse_reply = (buffer) => {
  const kind = buffer[0];
  if (kind === "+" || kind === "-" || kind === ":") {
    const end = buffer.indexOf("\r\n");
    if (end < 0) return undefined;
    const body = buffer.slice(1, end);
    if (kind === "-") throw new Error(`redis error: ${body}`);
    return kind === ":" ? Number(body) : body;
  }
  if (kind === "$") {
    const end = buffer.indexOf("\r\n");
    if (end < 0) return undefined;
    const size = Number(buffer.slice(1, end));
    if (size === -1) return null;
    if (buffer.length < end + 2 + size + 2) return undefined;
    return buffer.slice(end + 2, end + 2 + size);
  }
  throw new Error(`unexpected redis reply: ${JSON.stringify(buffer)}`);
};

const redis_command = (args) =>
  new Promise((resolve, reject) => {
    const { host, port } = redis_endpoint();
    const socket = net.connect({ host, port });
    let buffer = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`redis at ${host}:${port} did not answer`));
    }, 8000);
    socket.on("connect", () => socket.write(encode(args)));
    socket.on("data", (data) => {
      buffer += data.toString("latin1");
      let reply;
      try {
        reply = parse_reply(buffer);
      } catch (err) {
        clearTimeout(timer);
        socket.destroy();
        reject(err);
        return;
      }
      if (reply !== undefined) {
        clearTimeout(timer);
        socket.end();
        resolve(reply);
      }
    });
    socket.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });

// What rate_limit_key() builds in api/R/middleware_rate_limit.R: the kind the
// experiments endpoint passes ("exp"), the digest and the local date.
const rate_limit_key_for = (ip) => {
  const salt = process.env.IP_HASH_SALT || "";
  const hash = crypto
    .createHash("sha256")
    .update(salt + ip, "utf8")
    .digest("hex");
  const day = new Date().toISOString().slice(0, 10).replace(/-/g, "");
  return `exp:ip:${hash}:${day}`;
};

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
      });
    },
  },
};
