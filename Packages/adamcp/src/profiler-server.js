import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ProfilerClient } from "./profiler-client.js";
import { ProfilerSessionStore } from "./session-store.js";

const moduleDirectory = path.dirname(fileURLToPath(import.meta.url));
const defaultStaticDirectory = path.resolve(moduleDirectory, "../dist");

export class ProfilerServer {
  constructor(options = {}) {
    this.options = options;
    this.client = options.client ?? new ProfilerClient(options);
    this.store = options.store ?? new ProfilerSessionStore(options.sessionsDir);
    this.staticDirectory = options.staticDirectory ?? defaultStaticDirectory;
    this.server = null;
    this.captureTimers = new Map();
    this.eventStreams = new Set();
  }

  async start() {
    if (this.server) {
      return this.address();
    }
    this.server = http.createServer((request, response) => {
      this.handle(request, response).catch((error) => {
        if (!response.headersSent) {
          sendJSON(response, 500, { error: error.message });
        } else {
          response.end();
        }
      });
    });
    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.options.port ?? 0, this.options.host ?? "127.0.0.1", resolve);
    });
    return this.address();
  }

  address() {
    const address = this.server?.address();
    if (!address || typeof address === "string") {
      return null;
    }
    return `http://${address.address}:${address.port}`;
  }

  async close() {
    for (const timer of this.captureTimers.values()) {
      clearTimeout(timer);
    }
    this.captureTimers.clear();
    for (const response of this.eventStreams) {
      response.end();
    }
    this.eventStreams.clear();
    await this.client.close();
    if (this.server) {
      await new Promise((resolve) => this.server.close(resolve));
      this.server = null;
    }
  }

  async handle(request, response) {
    const url = new URL(request.url ?? "/", "http://localhost");
    if (url.pathname === "/api/targets" && request.method === "GET") {
      return sendJSON(response, 200, {
        targets: await this.client.listTargets(),
        selectedTarget: this.client.selectedTarget
      });
    }
    if (url.pathname === "/api/select" && request.method === "POST") {
      const body = await readJSONBody(request);
      return sendJSON(response, 200, { selectedTarget: await this.client.selectTarget(body.id) });
    }
    if (url.pathname === "/api/capabilities" && request.method === "GET") {
      return sendJSON(response, 200, await this.client.capabilities());
    }
    if (url.pathname === "/api/live" && request.method === "GET") {
      return sendJSON(response, 200, await this.client.liveSnapshot());
    }
    if (url.pathname === "/api/events" && request.method === "GET") {
      return this.streamLiveMetrics(request, response);
    }
    if (url.pathname === "/api/captures" && request.method === "GET") {
      return sendJSON(response, 200, { captures: await this.store.list() });
    }
    if (url.pathname === "/api/captures" && request.method === "POST") {
      const body = await readJSONBody(request);
      const capture = await this.client.startCapture(body);
      this.scheduleCaptureStop(capture);
      return sendJSON(response, 202, capture);
    }

    const captureMatch = url.pathname.match(/^\/api\/captures\/([a-zA-Z0-9-]+)(?:\/(stop|trace))?$/);
    if (captureMatch) {
      const [, id, action] = captureMatch;
      if (action === "stop" && request.method === "POST") {
        return sendJSON(response, 200, await this.stopAndPersist(id));
      }
      if (action === "trace" && request.method === "GET") {
        const trace = await this.store.trace(id);
        return trace ? sendJSON(response, 200, trace) : sendJSON(response, 404, { error: "Capture trace was not found." });
      }
      if (!action && request.method === "GET") {
        let capture = await this.store.get(id);
        if (!capture) {
          capture = await this.client.getCapture(id);
          if (capture?.manifest?.state === "completed") {
            capture = await this.store.save(capture, this.client.selectedTarget);
          }
        }
        return sendJSON(response, 200, capture);
      }
      if (!action && request.method === "DELETE") {
        await this.store.remove(id);
        response.writeHead(204).end();
        return;
      }
    }

    return this.serveStatic(url.pathname, response);
  }

  scheduleCaptureStop(capture) {
    const duration = capture?.durationMs;
    if (!capture?.id || !Number.isFinite(duration)) {
      return;
    }
    const timer = setTimeout(() => {
      this.stopAndPersist(capture.id).catch(() => {});
    }, duration);
    this.captureTimers.set(capture.id, timer);
  }

  async stopAndPersist(id) {
    const timer = this.captureTimers.get(id);
    if (timer) {
      clearTimeout(timer);
      this.captureTimers.delete(id);
    }
    let capture;
    try {
      capture = await this.client.stopCapture(id);
    } catch {
      capture = await this.client.getCapture(id);
    }
    return this.store.save(capture, this.client.selectedTarget);
  }

  async streamLiveMetrics(request, response) {
    response.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive"
    });
    let closed = false;
    this.eventStreams.add(response);
    request.once("close", () => { closed = true; });
    try {
      while (!closed) {
        try {
          const snapshot = await this.client.liveSnapshot();
          response.write(`event: metrics\ndata: ${JSON.stringify(snapshot)}\n\n`);
        } catch (error) {
          response.write(`event: profiler-error\ndata: ${JSON.stringify({ error: error.message })}\n\n`);
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
    } finally {
      this.eventStreams.delete(response);
    }
  }

  async serveStatic(pathname, response) {
    const requested = pathname === "/" ? "index.html" : pathname.replace(/^\//, "");
    const normalized = path.normalize(requested);
    if (normalized.startsWith("..")) {
      return sendJSON(response, 400, { error: "Invalid static asset path." });
    }
    let filePath = path.join(this.staticDirectory, normalized);
    try {
      const stats = await fs.stat(filePath);
      if (stats.isDirectory()) {
        filePath = path.join(filePath, "index.html");
      }
      const data = await fs.readFile(filePath);
      response.writeHead(200, { "Content-Type": contentType(filePath) });
      response.end(data);
    } catch (error) {
      if (error.code !== "ENOENT" || path.extname(normalized)) {
        return sendJSON(response, 404, { error: "Not found." });
      }
      const data = await fs.readFile(path.join(this.staticDirectory, "index.html"));
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      response.end(data);
    }
  }
}

function sendJSON(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

async function readJSONBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 1_000_000) {
      throw new Error("Request body is too large.");
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function contentType(filePath) {
  switch (path.extname(filePath)) {
    case ".html": return "text/html; charset=utf-8";
    case ".js": return "text/javascript; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".svg": return "image/svg+xml";
    default: return "application/octet-stream";
  }
}
