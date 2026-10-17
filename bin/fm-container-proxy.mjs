#!/usr/bin/env node
// Host-side egress proxy for one container-runtime launch.
//
// Usage: fm-container-proxy.mjs --socket <path> [--log <path>] --allow <host:port>...
//
// bin/fm-container-run.sh starts one per launch on a Unix socket in its private
// directory and mounts that socket into the container, whose --network none
// leaves it no other way out (bin/fm-container-lib.sh owns the network design).
// It speaks HTTP CONNECT only: a CONNECT whose host:port, compared without
// case, is exactly one of the --allow entries is tunnelled to that host, which
// is resolved here on the host; every other CONNECT is answered 403 and every
// plain HTTP request 405. TLS is never inspected. With --log, every decision is
// appended as one line naming the time, the verdict, and the requested
// host:port, never any request content.

import { appendFileSync } from "node:fs";
import http from "node:http";
import net from "node:net";

function die(message) {
  process.stderr.write(`fm-container-proxy: ${message}\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
let socketPath = "";
let logPath = "";
const allow = new Set();
for (let i = 0; i < args.length; i += 1) {
  const flag = args[i];
  const value = args[i + 1];
  if (value === undefined) die(`${flag} needs a value`);
  i += 1;
  if (flag === "--socket") socketPath = value;
  else if (flag === "--log") logPath = value;
  else if (flag === "--allow") {
    if (!/^[a-z0-9.-]+:[0-9]+$/i.test(value)) die(`--allow ${value} is not host:port`);
    allow.add(value.toLowerCase());
  } else die(`unknown flag ${flag}`);
}
if (!socketPath) die("--socket is required");
if (allow.size === 0) die("at least one --allow is required");

function record(verdict, ...parts) {
  if (!logPath) return;
  const safe = parts.map((part) => String(part).replace(/[^\x21-\x7e]/g, "?").slice(0, 300)).join(" ");
  try {
    appendFileSync(logPath, `${new Date().toISOString()} ${verdict} ${safe}\n`);
  } catch {
    // A log that cannot be written never changes a verdict.
  }
}

// The CONNECT target, normalised, or "" when it is not a plain host:port.
function connectTarget(url) {
  const match = /^([A-Za-z0-9.-]+):([0-9]{1,5})$/.exec(url || "");
  if (!match) return "";
  return `${match[1].toLowerCase()}:${Number(match[2])}`;
}

const server = http.createServer((req, res) => {
  record("refused-method", req.method, req.headers.host || "");
  res.writeHead(405, { "Content-Type": "text/plain", Connection: "close" });
  res.end("fm-container-proxy: only CONNECT to an allow-listed host is permitted\n");
});

server.on("connect", (req, client, head) => {
  const target = connectTarget(req.url);
  if (!target || !allow.has(target)) {
    record("refused", req.url);
    client.end("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nfm-container-proxy: host not on the container egress allow-list\n");
    return;
  }
  const port = Number(target.slice(target.lastIndexOf(":") + 1));
  const host = target.slice(0, target.lastIndexOf(":"));
  const upstream = net.connect(port, host, () => {
    record("allowed", target);
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head && head.length) upstream.write(head);
    upstream.pipe(client);
    client.pipe(upstream);
  });
  upstream.on("error", () => {
    record("upstream-error", target);
    client.end("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n");
  });
  client.on("error", () => upstream.destroy());
});

server.on("clientError", (_err, socket) => socket.destroy());
server.on("error", (err) => die(`cannot listen on ${socketPath}: ${err.message}`));
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, () => {
    server.close();
    process.exit(0);
  });
}
server.listen(socketPath);
