export class HttpMcpClient {
  constructor(endpointURL, { fetchImpl = globalThis.fetch } = {}) {
    if (!fetchImpl) {
      throw new Error("global fetch is unavailable; Node 18 or newer is required.");
    }
    this.endpointURL = endpointURL;
    this.fetchImpl = fetchImpl;
    this.sessionID = null;
  }

  async request(message) {
    const headers = {
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream"
    };
    if (this.sessionID) {
      headers["MCP-Session-Id"] = this.sessionID;
    }

    const response = await this.fetchImpl(this.endpointURL, {
      method: "POST",
      headers,
      body: JSON.stringify(message)
    });

    const sessionID = response.headers.get("MCP-Session-Id");
    if (sessionID) {
      this.sessionID = sessionID;
    }

    if (!("id" in message) || message.id === undefined || message.id === null) {
      if (response.status !== 202 && !response.ok) {
        throw new Error(`AdaMCP notification failed with HTTP ${response.status}`);
      }
      return null;
    }

    const body = await response.text();
    if (!response.ok) {
      return parseJSONRPCBody(body) ?? {
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32603, message: `AdaMCP HTTP ${response.status}` }
      };
    }

    return parseSSEMessage(body) ?? parseJSONRPCBody(body) ?? {
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32603, message: "AdaMCP returned an empty response." }
    };
  }

  async initialize(params) {
    const response = await this.request({
      jsonrpc: "2.0",
      id: "adamcp-initialize",
      method: "initialize",
      params: params ?? defaultInitializeParams()
    });
    if (response?.error) {
      throw new Error(response.error.message);
    }
    return response.result;
  }

  async close() {
    if (!this.sessionID) {
      return;
    }

    const sessionID = this.sessionID;
    this.sessionID = null;
    try {
      await this.fetchImpl(this.endpointURL, {
        method: "DELETE",
        headers: { "MCP-Session-Id": sessionID }
      });
    } catch {
      // Best effort session cleanup.
    }
  }
}

export function defaultInitializeParams() {
  return {
    protocolVersion: "2025-11-25",
    clientInfo: { name: "adamcp", version: "0.1.0" },
    capabilities: {}
  };
}

export function parseSSEMessage(text) {
  const events = text.split(/\n\n+/);
  for (const event of events) {
    const dataLines = event
      .split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trimStart());
    if (dataLines.length === 0) {
      continue;
    }
    return JSON.parse(dataLines.join("\n"));
  }
  return null;
}

function parseJSONRPCBody(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
