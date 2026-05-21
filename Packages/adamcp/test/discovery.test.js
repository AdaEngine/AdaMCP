import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { resolveServer, scanManifests } from "../src/discovery.js";

test("discovery scans tmp manifests, filters stale entries, and resolves selector", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "adamcp-discovery-"));
  const now = Date.now();

  await fs.writeFile(path.join(directory, "live.json"), JSON.stringify({
    schemaVersion: 1,
    id: "live-id",
    pid: 1,
    processName: "Live",
    serverName: "live-app",
    serverVersion: "1.0.0",
    endpointURL: "http://127.0.0.1:1234/mcp",
    startedAt: new Date(now).toISOString(),
    updatedAt: new Date(now).toISOString(),
    ttlSeconds: 30,
    metadata: { workspace: "AdaMCP" }
  }));
  await fs.writeFile(path.join(directory, "stale.json"), JSON.stringify({
    schemaVersion: 1,
    id: "stale-id",
    pid: 2,
    processName: "Stale",
    serverName: "stale-app",
    serverVersion: "1.0.0",
    endpointURL: "http://127.0.0.1:1235/mcp",
    startedAt: new Date(now - 60000).toISOString(),
    updatedAt: new Date(now - 60000).toISOString(),
    ttlSeconds: 1,
    metadata: {}
  }));

  const manifests = await scanManifests({ discoveryDir: directory, now });
  assert.equal(manifests.length, 1);
  assert.equal(manifests[0].id, "live-id");
  assert.equal(resolveServer(manifests, "live-app").endpointURL, "http://127.0.0.1:1234/mcp");

  await assert.rejects(fs.stat(path.join(directory, "stale.json")), { code: "ENOENT" });
  await fs.rm(directory, { recursive: true, force: true });
});
