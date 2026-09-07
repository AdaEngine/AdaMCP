import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { AdamcpRouter } from "../src/router.js";

test("run_file reads real YAML and forwards source and exact failure report", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "adamcp-flow-"));
  try {
    const filename = path.join(dir, "scenario.yaml");
    const source = "- tapOn:\n    id: button.play\n";
    await fs.writeFile(filename, source);
    const expected = { content: [{ type: "text", text: '{"failedStep":0}' }], isError: true };
    const router = new AdamcpRouter();
    const requests = [];
    router.client = { request: async (request) => { requests.push(request); return { result: expected }; } };
    const response = await router.handle({ jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: "adamcp.run_file", arguments: { path: filename } } });
    assert.deepEqual(requests[0].params, { name: "automation.run", arguments: { source } });
    assert.deepEqual(response.result, expected);
    for (const invalid of ["relative.yaml", dir, path.join(dir, "missing.yaml")]) {
      const result = await router.callRouterTool({ name: "adamcp.run_file", arguments: { path: invalid } });
      assert.equal(result.isError, true);
    }
    await fs.writeFile(filename, Buffer.alloc(1048577));
    assert.equal((await router.callRouterTool({ name: "adamcp.run_file", arguments: { path: filename } })).isError, true);
    assert.equal(requests.length, 1);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
