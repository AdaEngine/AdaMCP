import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ProfilerServer } from "../src/profiler-server.js";
import { ProfilerSessionStore } from "../src/session-store.js";

test("profiler server serves live data and persists stopped captures", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "adamcp-profiler-server-"));
  const staticDirectory = path.join(root, "dist");
  const sessionsDirectory = path.join(root, "sessions");
  await fs.mkdir(staticDirectory);
  await fs.writeFile(path.join(staticDirectory, "index.html"), "<h1>AdaMCP Profiler</h1>");

  const capture = {
    manifest: { id: "capture-1", state: "completed", startedAt: "2026-08-05T00:00:00Z" },
    summary: { frameCount: 4 },
    spans: [],
    trace: { traceEvents: [{ name: "frame", ph: "X" }] },
    artifacts: []
  };
  const client = {
    selectedTarget: { id: "game", processName: "Game" },
    async listTargets() { return [this.selectedTarget]; },
    async capabilities() { return { providers: { cpuFrame: { supported: true } } }; },
    async liveSnapshot() { return { summary: { fps: 60 } }; },
    async startCapture() { return { id: "capture-1", state: "recording", durationMs: 60_000 }; },
    async stopCapture() { return capture; },
    async getCapture() { return capture; },
    async selectTarget() { return this.selectedTarget; },
    async close() {}
  };
  const server = new ProfilerServer({
    client,
    store: new ProfilerSessionStore(sessionsDirectory),
    staticDirectory,
    host: "127.0.0.1",
    port: 0
  });

  try {
    const address = await server.start();
    assert.equal((await (await fetch(`${address}/api/live`)).json()).summary.fps, 60);
    assert.match(await (await fetch(address)).text(), /AdaMCP Profiler/);

    const started = await fetch(`${address}/api/captures`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ durationMs: 5000 })
    });
    assert.equal(started.status, 202);

    const stopped = await fetch(`${address}/api/captures/capture-1/stop`, { method: "POST" });
    assert.equal((await stopped.json()).manifest.target.id, "game");
    assert.equal((await (await fetch(`${address}/api/captures`)).json()).captures.length, 1);
    assert.equal((await (await fetch(`${address}/api/captures/capture-1/trace`)).json()).traceEvents.length, 1);

    const removed = await fetch(`${address}/api/captures/capture-1`, { method: "DELETE" });
    assert.equal(removed.status, 204);
  } finally {
    await server.close();
    await fs.rm(root, { recursive: true, force: true });
  }
});
