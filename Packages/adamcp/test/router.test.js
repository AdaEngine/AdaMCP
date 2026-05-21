import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { AdamcpRouter } from "../src/router.js";
import { startFakeHTTPMCPServer } from "../test_helpers/fake-http-mcp.js";

test("router returns helpful no-server status", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "adamcp-router-empty-"));
  const router = new AdamcpRouter({ discoveryDir: directory });

  const initialized = await router.handle({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", clientInfo: { name: "test", version: "1.0.0" }, capabilities: {} }
  });
  assert.equal(initialized.result.serverInfo.name, "adamcp-router");
  assert.match(initialized.result.instructions, /AdaEngine application with AdaMCP is not running/);

  const call = await router.handle({
    jsonrpc: "2.0",
    id: 2,
    method: "tools/call",
    params: { name: "adamcp.status", arguments: {} }
  });
  assert.match(call.result.content[0].text, /not running/);

  await router.close();
  await fs.rm(directory, { recursive: true, force: true });
});

test("router lists multiple servers and selects by id", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "adamcp-router-many-"));
  const first = await startFakeHTTPMCPServer("first-app");
  const second = await startFakeHTTPMCPServer("second-app");
  try {
    await writeManifest(directory, "first", "first-app", first.url);
    await writeManifest(directory, "second", "second-app", second.url);

    const router = new AdamcpRouter({ discoveryDir: directory });
    const initialized = await router.handle({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-11-25", clientInfo: { name: "test", version: "1.0.0" }, capabilities: {} }
    });
    assert.equal(initialized.result.serverInfo.name, "adamcp-router");

    const listed = await router.handle({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "adamcp.list_servers", arguments: {} }
    });
    assert.match(listed.result.content[0].text, /second-app/);

    const selected = await router.handle({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "adamcp.select_server", arguments: { id: "second" } }
    });
    assert.match(selected.result.content[0].text, /second-app/);

    const tools = await router.handle({ jsonrpc: "2.0", id: 4, method: "tools/list", params: {} });
    assert.equal(tools.result.tools[0].name, "world.list_worlds");

    await router.close();
  } finally {
    await first.close();
    await second.close();
    await fs.rm(directory, { recursive: true, force: true });
  }
});

async function writeManifest(directory, id, serverName, endpointURL) {
  const now = new Date().toISOString();
  await fs.writeFile(path.join(directory, `${id}.json`), JSON.stringify({
    schemaVersion: 1,
    id,
    pid: process.pid,
    processName: serverName,
    serverName,
    serverVersion: "1.0.0",
    endpointURL,
    startedAt: now,
    updatedAt: now,
    ttlSeconds: 30,
    metadata: {}
  }));
}
