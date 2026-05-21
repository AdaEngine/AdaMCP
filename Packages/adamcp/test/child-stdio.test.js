import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { encodeFrame, readFrames } from "../src/stdio.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

test("child stdio proxy forwards frames", async () => {
  const cliPath = path.resolve(__dirname, "../bin/adamcp.js");
  const childPath = path.resolve(__dirname, "../test_helpers/child-mcp.js");
  const processUnderTest = spawn(process.execPath, [
    cliPath,
    "--stdio-command",
    `${process.execPath} ${childPath}`
  ], { stdio: ["pipe", "pipe", "pipe"] });

  const frames = [];
  const reader = (async () => {
    for await (const frame of readFrames(processUnderTest.stdout)) {
      frames.push(JSON.parse(frame.toString("utf8")));
      processUnderTest.stdin.end();
    }
  })();

  processUnderTest.stdin.write(encodeFrame({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", clientInfo: { name: "test", version: "1.0.0" }, capabilities: {} }
  }));

  await Promise.race([
    reader,
    new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for child proxy")), 2000))
  ]);

  assert.equal(frames[0].result.serverInfo.name, "child-mcp");
});
