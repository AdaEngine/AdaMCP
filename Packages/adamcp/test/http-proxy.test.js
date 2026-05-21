import assert from "node:assert/strict";
import test from "node:test";
import { HttpMcpClient } from "../src/http-proxy.js";
import { startFakeHTTPMCPServer } from "../test_helpers/fake-http-mcp.js";

test("HTTP proxy handles initialize session and SSE tool call", async () => {
  const server = await startFakeHTTPMCPServer("fake-app");
  try {
    const client = new HttpMcpClient(server.url);
    const initialize = await client.request({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        clientInfo: { name: "test", version: "1.0.0" },
        capabilities: {}
      }
    });

    assert.equal(initialize.result.serverInfo.name, "fake-app");
    assert.equal(client.sessionID, "session-fake-app");

    const tools = await client.request({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    assert.equal(tools.result.tools[0].name, "world.list_worlds");

    await client.close();
    assert.equal(server.deletedSessions, 1);
  } finally {
    await server.close();
  }
});
