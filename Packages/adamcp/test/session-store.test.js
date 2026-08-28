import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ProfilerSessionStore } from "../src/session-store.js";

test("profiler session store persists report, manifest, and trace", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "adamcp-profiles-"));
  const store = new ProfilerSessionStore(directory);
  const capture = {
    manifest: { id: "capture-1", state: "completed", startedAt: "2026-08-05T00:00:00Z" },
    summary: { frameCount: 2 },
    spans: [{ name: "AppWorlds.update" }],
    trace: { traceEvents: [{ name: "frame", ph: "X" }] },
    artifacts: []
  };

  try {
    await store.save(capture, { id: "game" });
    assert.equal((await store.list())[0].target.id, "game");
    assert.equal((await store.get("capture-1")).summary.frameCount, 2);
    assert.equal((await store.trace("capture-1")).traceEvents[0].name, "frame");
    assert.equal(JSON.parse(await fs.readFile(path.join(directory, "capture-1", "events.json"), "utf8"))[0].name, "AppWorlds.update");
    assert.equal(JSON.parse(await fs.readFile(path.join(directory, "capture-1", "summary.json"), "utf8")).frameCount, 2);

    await store.remove("capture-1");
    assert.equal(await store.get("capture-1"), null);
    await assert.rejects(() => store.get("../escape"), /Invalid profiler session id/);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});
