import http from "node:http";

export async function startFakeHTTPMCPServer(name) {
  let deletedSessions = 0;
  const server = http.createServer(async (request, response) => {
    if (request.url !== "/mcp") {
      response.writeHead(404).end();
      return;
    }
    if (request.method === "DELETE") {
      deletedSessions += 1;
      response.writeHead(200, { "MCP-Session-Id": `session-${name}` }).end();
      return;
    }

    const body = await readRequestBody(request);
    const message = JSON.parse(body);
    const isInitialize = message.method === "initialize";
    const sessionID = request.headers["mcp-session-id"];
    if (!isInitialize && sessionID !== `session-${name}`) {
      response.writeHead(404, { "Content-Type": "application/json" }).end(JSON.stringify({
        jsonrpc: "2.0",
        id: message.id ?? null,
        error: { code: -32600, message: "missing session" }
      }));
      return;
    }

    if (!("id" in message)) {
      response.writeHead(202, { "MCP-Session-Id": `session-${name}` }).end();
      return;
    }

    const rpcResponse = responseFor(name, message);
    response.writeHead(200, {
      "Content-Type": "text/event-stream",
      "MCP-Session-Id": `session-${name}`,
      "Connection": "close"
    });
    response.end(`event: message\ndata: ${JSON.stringify(rpcResponse)}\n\n`);
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  return {
    url: `http://127.0.0.1:${address.port}/mcp`,
    get deletedSessions() {
      return deletedSessions;
    },
    close: () => new Promise((resolve) => server.close(resolve))
  };
}

function responseFor(name, message) {
  if (message.method === "initialize") {
    return {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: message.params?.protocolVersion ?? "2025-11-25",
        capabilities: { tools: { listChanged: false }, resources: { listChanged: false } },
        serverInfo: { name, version: "1.0.0" },
        instructions: `Fake ${name}`
      }
    };
  }
  if (message.method === "tools/list") {
    return {
      jsonrpc: "2.0",
      id: message.id,
      result: {
        tools: [{ name: "world.list_worlds", description: "List worlds", inputSchema: { type: "object" } }]
      }
    };
  }
  return { jsonrpc: "2.0", id: message.id, result: {} };
}

function readRequestBody(request) {
  return new Promise((resolve) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => resolve(body));
  });
}
