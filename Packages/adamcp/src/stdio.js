export async function* readFrames(stream) {
  let buffer = Buffer.alloc(0);
  for await (const chunk of stream) {
    buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
    while (true) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) {
        break;
      }

      const header = buffer.subarray(0, headerEnd).toString("utf8");
      const match = /^content-length:\s*(\d+)$/im.exec(header);
      if (!match) {
        throw new Error("Missing Content-Length header");
      }

      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      const bodyEnd = bodyStart + length;
      if (buffer.length < bodyEnd) {
        break;
      }

      yield buffer.subarray(bodyStart, bodyEnd);
      buffer = buffer.subarray(bodyEnd);
    }
  }
}

export function encodeFrame(message) {
  const body = Buffer.from(
    typeof message === "string" || Buffer.isBuffer(message)
      ? message
      : JSON.stringify(message),
    "utf8"
  );
  return Buffer.concat([
    Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "utf8"),
    body
  ]);
}

export function writeFrame(stream, message) {
  stream.write(encodeFrame(message));
}
