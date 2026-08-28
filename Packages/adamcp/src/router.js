import { scanManifests, resolveServer } from "./discovery.js";
import { defaultInitializeParams, HttpMcpClient } from "./http-proxy.js";

const NO_APP_MESSAGE = "AdaEngine application with AdaMCP is not running. Build and launch the app before continuing.";

export class AdamcpRouter {
  constructor(options = {}) {
    this.options = options;
    this.client = null;
    this.selectedServer = null;
    this.manifests = [];
    this.initializeParams = null;
    this.selectionError = null;
  }

  async handle(request) {
    const expectsResponse = "id" in request && request.id !== undefined && request.id !== null;

    if (request.method === "initialize") {
      this.initializeParams = request.params ?? defaultInitializeParams();
      const downstream = await this.tryAutoConnect(request.id);
      if (downstream) {
        return downstream;
      }
      return this.routerInitializeResponse(request.id);
    }

    if (request.method === "tools/list") {
      if (!this.client) {
        return result(request.id, { tools: [...routerTools(), ...profilerTools()] });
      }
      const downstream = await this.client.request(request);
      if (downstream?.result?.tools) {
        downstream.result.tools = [...downstream.result.tools, ...routerTools(), ...profilerTools()];
      }
      return downstream;
    }

    if (request.method === "tools/call" && this.isRouterTool(request.params?.name)) {
      return result(request.id, await this.callRouterTool(request.params));
    }

    if (!this.client) {
      if (!expectsResponse) {
        return null;
      }
      if (request.method === "resources/list") {
        return result(request.id, { resources: [] });
      }
      if (request.method === "resources/templates/list") {
        return result(request.id, { resourceTemplates: [], templates: [] });
      }
      return error(request.id, -32002, this.statusMessage());
    }

    return this.client.request(request);
  }

  async close() {
    await this.client?.close();
    this.client = null;
  }

  async tryAutoConnect(requestID) {
    if (this.options.url) {
      this.selectedServer = {
        id: "direct-url",
        serverName: "direct-url",
        serverVersion: "",
        endpointURL: this.options.url,
        metadata: {}
      };
      return this.connectSelected(requestID);
    }

    await this.refreshManifests();
    let selected = null;
    try {
      selected = resolveServer(this.manifests, this.options.server);
      this.selectionError = null;
    } catch (error) {
      this.selectionError = error.message;
    }

    if (!selected) {
      return null;
    }

    this.selectedServer = selected;
    return this.connectSelected(requestID);
  }

  async connectSelected(requestID = "adamcp-connect") {
    await this.client?.close();
    this.client = new HttpMcpClient(this.selectedServer.endpointURL);
    try {
      return await this.client.request({
        jsonrpc: "2.0",
        id: requestID,
        method: "initialize",
        params: this.initializeParams ?? defaultInitializeParams()
      });
    } catch (errorObject) {
      await this.client.close();
      this.client = null;
      return error(requestID, -32003, `Failed to connect to AdaMCP server '${this.selectedServer.id}': ${errorObject.message}`);
    }
  }

  async callRouterTool(params = {}) {
    const args = params.arguments ?? {};
    switch (params.name) {
      case "adamcp.status":
        await this.refreshManifests();
        return toolResult(this.statusPayload());
      case "adamcp.list_servers":
        await this.refreshManifests();
        return toolResult({ servers: this.manifests, selectedServer: this.selectedServer });
      case "adamcp.select_server": {
        await this.refreshManifests();
        const selector = args.id ?? args.server ?? args.serverName ?? args.name;
        const selected = resolveServer(this.manifests, selector);
        this.selectedServer = selected;
        const initializeResponse = await this.connectSelected("adamcp-select-initialize");
        if (initializeResponse.error) {
          return toolResult(initializeResponse.error, true);
        }
        return toolResult({ selectedServer: selected, initializeResult: initializeResponse.result });
      }
      case "adamcp.profiler.status":
        return this.callProfilerStatus();
      case "adamcp.profiler.start":
        return this.callDownstreamProfiler("profiler.start_capture", args);
      case "adamcp.profiler.stop":
        return this.callDownstreamProfiler("profiler.stop_capture", args);
      case "adamcp.profiler.get_report":
        return this.callDownstreamProfiler("profiler.get_capture", args);
      case "adamcp.profiler.export": {
        const report = await this.downstreamProfilerPayload("profiler.get_capture", args);
        return toolResult(args.format === "trace" ? report.trace : report);
      }
      default:
        return toolResult({ message: `Unknown router tool '${params.name}'.` }, true);
    }
  }

  async callProfilerStatus() {
    try {
      const [capabilities, live, captures] = await Promise.all([
        this.downstreamProfilerPayload("profiler.capabilities"),
        this.downstreamProfilerPayload("profiler.live_snapshot"),
        this.downstreamProfilerPayload("profiler.list_captures")
      ]);
      return toolResult({ selectedServer: this.selectedServer, capabilities, live, captures });
    } catch (errorObject) {
      return toolResult({ message: errorObject.message }, true);
    }
  }

  async callDownstreamProfiler(name, args) {
    try {
      return toolResult(await this.downstreamProfilerPayload(name, args));
    } catch (errorObject) {
      return toolResult({ message: errorObject.message }, true);
    }
  }

  async downstreamProfilerPayload(name, args = {}) {
    if (!this.client) {
      throw new Error(this.statusMessage());
    }
    const response = await this.client.request({
      jsonrpc: "2.0",
      id: `adamcp-profiler-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      method: "tools/call",
      params: { name, arguments: args }
    });
    if (response?.error) {
      throw new Error(response.error.message);
    }
    const resultObject = response?.result;
    const text = resultObject?.content?.find((content) => content.type === "text")?.text;
    const payload = text ? JSON.parse(text) : null;
    if (resultObject?.isError) {
      throw new Error(payload?.message ?? "AdaMCP profiler request failed.");
    }
    return payload;
  }

  async refreshManifests() {
    this.manifests = await scanManifests({ discoveryDir: this.options.discoveryDir });
  }

  isRouterTool(name) {
    return name === "adamcp.status"
      || name === "adamcp.list_servers"
      || name === "adamcp.select_server"
      || name?.startsWith("adamcp.profiler.");
  }

  routerInitializeResponse(id) {
    return result(id, {
      protocolVersion: this.initializeParams?.protocolVersion ?? "2025-11-25",
      capabilities: { tools: { listChanged: false }, resources: { listChanged: false } },
      serverInfo: { name: "adamcp-router", version: "0.1.0" },
      instructions: this.statusMessage()
    });
  }

  statusMessage() {
    if (this.selectionError) {
      return `${this.selectionError} Use adamcp.list_servers and adamcp.select_server to choose a live server.`;
    }
    if (this.manifests.length > 1) {
      return "Multiple live AdaMCP servers were found. Use adamcp.list_servers and adamcp.select_server before inspecting the app.";
    }
    return NO_APP_MESSAGE;
  }

  statusPayload() {
    return {
      message: this.statusMessage(),
      selectedServer: this.selectedServer,
      serverCount: this.manifests.length,
      servers: this.manifests
    };
  }
}

function routerTools() {
  return [
    {
      name: "adamcp.status",
      description: "Show AdaMCP router status and explain whether a live AdaEngine app is available.",
      inputSchema: objectSchema()
    },
    {
      name: "adamcp.list_servers",
      description: "List live AdaMCP servers discovered on this machine.",
      inputSchema: objectSchema()
    },
    {
      name: "adamcp.select_server",
      description: "Select one live AdaMCP server by id or unique server name.",
      inputSchema: objectSchema({
        id: { type: "string" },
        server: { type: "string" },
        serverName: { type: "string" },
        name: { type: "string" }
      })
    }
  ];
}

function profilerTools() {
  return [
    {
      name: "adamcp.profiler.status",
      description: "Return profiler capabilities, live metrics, and capture state for the selected AdaEngine app.",
      inputSchema: objectSchema()
    },
    {
      name: "adamcp.profiler.start",
      description: "Start a bounded frame profiler capture in the selected AdaEngine app.",
      inputSchema: objectSchema({
        preset: { type: "string", enum: ["frame"] },
        durationMs: { type: "integer" },
        frameCount: { type: "integer" },
        frameBudgetMs: { type: "number" }
      })
    },
    {
      name: "adamcp.profiler.stop",
      description: "Stop the active profiler capture and return its report.",
      inputSchema: objectSchema({ id: { type: "string" } })
    },
    {
      name: "adamcp.profiler.get_report",
      description: "Get an active or completed profiler report.",
      inputSchema: objectSchema({ id: { type: "string" } })
    },
    {
      name: "adamcp.profiler.export",
      description: "Export a profiler capture as the full report or a Perfetto-compatible trace object.",
      inputSchema: objectSchema({
        id: { type: "string" },
        format: { type: "string", enum: ["report", "trace"] }
      })
    }
  ];
}

function objectSchema(properties = {}) {
  return { type: "object", properties };
}

function toolResult(payload, isError = false) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    isError
  };
}

function result(id, payload) {
  return { jsonrpc: "2.0", id, result: payload };
}

function error(id, code, message) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}
