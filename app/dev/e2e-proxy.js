// The header a browser cannot set (section 5.4).
//
// `client_ip()` reads X-Client-IP, then CF-Connecting-IP, then REMOTE_ADDR.
// Shiny takes those off the WebSocket handshake, and a page cannot put headers
// on a WebSocket -- so without something in front, every session is seen as
// 127.0.0.1 and a test of "the app forwarded the IP it saw" would compare the
// socket address against itself and pass for the wrong reason.
//
// That is what Nginx does in production, so the proxy is not test scaffolding
// pretending to be the product: it is the product's edge, at one port. Every
// spec runs through it, which means every spec exercises the header path.
//
//   node dev/e2e-proxy.js            # 3839 -> 3838, X-Client-IP: 203.0.113.9
//
// Both the HTTP requests and the WebSocket upgrade carry the header: Shiny's
// session is created from the upgrade, not from the page load.
const http = require("http");
const net = require("net");

const APP_HOST = process.env.PROXY_UPSTREAM_HOST || "127.0.0.1";
const APP_PORT = Number(process.env.PROXY_UPSTREAM_PORT || 3838);
const LISTEN_PORT = Number(process.env.PROXY_PORT || 3839);
// TEST-NET-3 (RFC 5737): an address that cannot route anywhere, so it can be
// asserted without ever looking like a real visitor.
const CLIENT_IP = process.env.PROXY_CLIENT_IP || "203.0.113.9";

// Hop-by-hop headers belong to the connection, not to the message: forwarding
// them is how a proxy ends up advertising a transfer-encoding it is not
// honouring.
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const without_hop_by_hop = (headers) => {
  const out = {};
  for (const [key, value] of Object.entries(headers)) {
    if (!HOP_BY_HOP.has(key.toLowerCase())) out[key] = value;
  }
  return out;
};

const proxied_headers = (headers) => {
  const out = without_hop_by_hop(headers);
  out["x-client-ip"] = CLIENT_IP;
  // What Nginx's proxy_set_header Host does: the address the upstream binds,
  // not the one the browser typed.
  out.host = `${APP_HOST}:${APP_PORT}`;
  return out;
};

// The upgrade is the one place where "hop-by-hop" is the whole point:
// `Connection: Upgrade` and `Upgrade: websocket` are what make httpuv switch
// protocols instead of answering an ordinary request, so stripping them -- as
// the message path correctly does -- leaves Shiny serving a 400 and the
// session never opens. Everything else stays, including
// Sec-WebSocket-Extensions, because the compression both ends agree on has to
// be the same one on the other side of the socket.
const proxied_upgrade_headers = (headers) => {
  const out = {};
  for (const [key, value] of Object.entries(headers)) {
    const lower = key.toLowerCase();
    if (lower === "proxy-authorization" || lower === "proxy-connection") continue;
    out[key] = value;
  }
  out["x-client-ip"] = CLIENT_IP;
  out.host = `${APP_HOST}:${APP_PORT}`;
  return out;
};

const server = http.createServer((req, res) => {
  const upstream = http.request(
    {
      host: APP_HOST,
      port: APP_PORT,
      method: req.method,
      path: req.url,
      headers: proxied_headers(req.headers),
    },
    (upstream_res) => {
      res.writeHead(
        upstream_res.statusCode || 502,
        without_hop_by_hop(upstream_res.headers),
      );
      upstream_res.pipe(res);
    },
  );
  upstream.on("error", (err) => {
    // A dead upstream has to fail the request, not hang Cypress until its own
    // timeout: the app is started by the same script that starts this.
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`upstream ${APP_HOST}:${APP_PORT}: ${err.message}`);
    } else {
      res.destroy();
    }
  });
  req.pipe(upstream);
});

server.on("upgrade", (req, socket, head) => {
  const headers = proxied_upgrade_headers(req.headers);
  // The proxy log is the first place a dead session shows up, so record the
  // handshake rather than only the failure it causes later.
  console.log(`upgrade ${req.url}`);
  const upstream = net.connect(APP_PORT, APP_HOST, () => {
    const request_line = `${req.method} ${req.url} HTTP/1.1`;
    const header_lines = Object.entries(headers).flatMap(([key, value]) =>
      [].concat(value).map((v) => `${key}: ${v}`),
    );
    upstream.write([request_line, ...header_lines, "", ""].join("\r\n"));
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream);
    upstream.pipe(socket);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

server.listen(LISTEN_PORT, "127.0.0.1", () => {
  console.log(
    `e2e-proxy: 127.0.0.1:${LISTEN_PORT} -> ${APP_HOST}:${APP_PORT} with X-Client-IP ${CLIENT_IP}`,
  );
});
