import { scanManifests, resolveServer } from "./discovery.js";
import { defaultInitializeParams, HttpMcpClient } from "./http-proxy.js";

export class ProfilerClient {
  constructor(options = {}) {
    this.options = options;
    this.client = null;
    this.selectedTarget = null;
  }

  async listTargets() {
    if (this.options.url) {
      return [{
        id: "direct-url",
        pid: null,
        processName: "Direct AdaMCP target",
        serverName: this.options.server ?? "direct-url",
        serverVersion: "",
        endpointURL: this.options.url,
        metadata: {}
      }];
    }
    return scanManifests({ discoveryDir: this.options.discoveryDir });
  }

  async ensureConnected() {
    if (this.client) {
      return this.selectedTarget;
    }
    const targets = await this.listTargets();
    const selected = resolveServer(targets, this.options.server) ?? (targets.length === 1 ? targets[0] : null);
    if (!selected) {
      throw new Error(targets.length === 0
        ? "No live AdaEngine app was discovered."
        : "Multiple live AdaEngine apps were found; select a target first.");
    }
    await this.selectTarget(selected.id);
    return this.selectedTarget;
  }

  async selectTarget(selector) {
    const targets = await this.listTargets();
    const selected = resolveServer(targets, selector);
    await this.client?.close();
    const client = new HttpMcpClient(selected.endpointURL);
    await client.initialize(defaultInitializeParams());
    this.client = client;
    this.selectedTarget = selected;
    return selected;
  }

  async callTool(name, argumentsObject = {}) {
    await this.ensureConnected();
    const response = await this.client.request({
      jsonrpc: "2.0",
      id: `profiler-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      method: "tools/call",
      params: { name, arguments: argumentsObject }
    });
    if (response?.error) {
      throw new Error(response.error.message);
    }
    const result = response?.result;
    const text = result?.content?.find((content) => content.type === "text")?.text;
    let payload = null;
    try {
      payload = text ? JSON.parse(text) : null;
    } catch {
      payload = { message: text ?? "AdaMCP returned an empty profiler response." };
    }
    if (result?.isError) {
      throw new Error(payload?.message ?? payload?.code ?? "AdaMCP profiler request failed.");
    }
    return payload;
  }

  capabilities() {
    return this.callTool("profiler.capabilities");
  }

  liveSnapshot(options = {}) {
    return this.callTool("profiler.live_snapshot", options);
  }

  startCapture(options = {}) {
    return this.callTool("profiler.start_capture", options);
  }

  stopCapture(id) {
    return this.callTool("profiler.stop_capture", id ? { id } : {});
  }

  getCapture(id) {
    return this.callTool("profiler.get_capture", id ? { id } : {});
  }

  async close() {
    await this.client?.close();
    this.client = null;
    this.selectedTarget = null;
  }
}
