import { readFrames, writeFrame } from "../src/stdio.js";

for await (const frame of readFrames(process.stdin)) {
  const request = JSON.parse(frame.toString("utf8"));
  if (!("id" in request)) {
    continue;
  }

  if (request.method === "initialize") {
    writeFrame(process.stdout, {
      jsonrpc: "2.0",
      id: request.id,
      result: {
        protocolVersion: request.params?.protocolVersion ?? "2025-11-25",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "child-mcp", version: "1.0.0" },
        instructions: "child fixture"
      }
    });
  } else {
    writeFrame(process.stdout, { jsonrpc: "2.0", id: request.id, result: {} });
  }
}
