import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import test from "node:test";
import { encodeFrame, readFrames } from "../src/stdio.js";

test("stdio frame parser and serializer roundtrip", async () => {
  const stream = new PassThrough();
  const request = { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} };
  const frames = [];

  const reader = (async () => {
    for await (const frame of readFrames(stream)) {
      frames.push(JSON.parse(frame.toString("utf8")));
    }
  })();

  stream.end(encodeFrame(request));
  await reader;

  assert.deepEqual(frames, [request]);
});
