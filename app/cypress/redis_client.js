// RESP by hand over a socket, shared by two callers:
//
//   cypress.config.cjs -- the tasks a spec runs (redis_flush_db, rate_limit_key).
//   dev/load_test.sh   -- `node cypress/redis_client.js FLUSHDB` once per run,
//                        because every session of a load run gets its own
//                        client IP and the counter that matters is per IP.
//
// The image has node but no redis client, and adding one to keep a dozen lines
// of protocol out of here is the worse trade. The reply parser only handles
// what those callers answer -- status, error, integer, bulk and nil -- because
// a parser nobody exercises is a parser that lies.
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

// What api/R/middleware_rate_limit.R builds: the kind the experiments
// endpoint passes ("exp"), the digest and the local date.
const rate_limit_key_for = (ip) => {
  const salt = process.env.IP_HASH_SALT || "";
  const hash = crypto
    .createHash("sha256")
    .update(salt + ip, "utf8")
    .digest("hex");
  const day = new Date().toISOString().slice(0, 10).replace(/-/g, "");
  return `exp:ip:${hash}:${day}`;
};

module.exports = { redis_command, rate_limit_key_for };

// `node cypress/redis_client.js FLUSHDB` (or GET <key>): the shell side of
// the same client, so load_test.sh does not have to speak RESP itself.
if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    process.stderr.write("usage: node cypress/redis_client.js <command> [args...]\n");
    process.exit(2);
  }
  redis_command(args).then(
    (reply) => {
      process.stdout.write(`${reply === null ? "(nil)" : reply}\n`);
    },
    (err) => {
      process.stderr.write(`${err.message}\n`);
      process.exit(1);
    },
  );
}
