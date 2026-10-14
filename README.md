# AdaMCP - MCP Server for AdaEngine

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAdaEngine%2FAdaMCP%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/AdaEngine/AdaMCP)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAdaEngine%2FAdaMCP%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/AdaEngine/AdaMCP)

`AdaMCP` exposes a live AdaEngine application as an MCP server. It is built for inspection-first workflows: world/entity/resource introspection, render capture, and AdaUI tree inspection with a small set of safe UI actions.

📚 Check [documentation](https://swiftpackageindex.com/AdaEngine/AdaMCP/main/documentation/adamcpcore) to learn more

## Current platform support 

The important distinction is:

- MCP clients can live anywhere and connect over HTTP or stdio.
- The host runtime now builds on the broader Apple surface, while `stdio` remains primarily a local host transport and HTTP is the main cross-device option.

## What you get 🌸

- 😳 World, entity, component, resource, and asset inspection.
- 📸 Screenshot capture for live render output.
- 💉 AdaUI inspection tools such as `ui.list_windows`, `ui.get_tree`, `ui.get_node`, `ui.find_nodes`, `ui.capture_node_screenshot`, and `ui.hit_test`.
- 🧑‍🏫 AdaUI diagnostics and safe actions such as focus traversal, deterministic tap, and scroll-to-node.
- 📦 MCP resources under `ada://...`, including `ada://ui/windows`, `ada://ui/window/{id}`, `ada://ui/tree/{id}`, and `ada://ui/node/{windowId}/{nodeRef}`.

## Embedding in an AdaEngine app ⚒️

Add the release as a SwiftPM dependency. The revision requirement allows the
runtime to follow AdaEngine's `main` branch:

```swift
dependencies: [
    .package(url: "https://github.com/AdaEngine/AdaMCP.git", revision: "v0.2.0")
]
```

Then add the plugin to your app:

```swift
import AdaEngine
import AdaMCPPlugin

@main
struct ExampleApp: App {
    var body: some AppScene {
        WindowGroup {
            RootView()
        }
        .addPlugins(
            MCPPlugin(configuration: .init(
                enableHTTP: true,
                enableStdio: true,
                host: "127.0.0.1",
                port: 2510,
                endpoint: "/mcp",
                serverName: "example-app",
                serverVersion: "0.1.0",
                instructions: "Inspect the live AdaEngine runtime."
            ))
        )
    }
}
```

## Connect from an agent with npx

Install the MCP server in your agent configuration with the npm package:

```json
{
  "mcpServers": {
    "adamcp": {
      "command": "npx",
      "args": ["-y", "adamcp@latest"]
    }
  }
}
```

The `adamcp` CLI speaks MCP over stdio to the agent. It discovers live AdaEngine apps through AdaMCP discovery manifests and connects to the selected app over HTTP. If no app is running, the router starts successfully and tells the agent to build and launch the AdaEngine app before continuing.

Useful overrides:

- `ADAMCP_URL` or `--url` connects directly to an HTTP MCP endpoint.
- `ADAMCP_SERVER` or `--server` selects a discovery manifest by exact `id` or unique `serverName`.
- `ADAMCP_DISCOVERY_DIR` or `--discovery-dir` points at a custom manifest directory.
- `ADAMCP_STDIO_COMMAND` or `--stdio-command` launches an AdaEngine app/server as a child stdio MCP process and proxies bytes transparently.

When multiple live apps are found, use the router tools `adamcp.list_servers` and `adamcp.select_server`.

## Local web profiler

Launch the CPU-first dashboard while an AdaEngine app with the embedded AdaMCP plugin is running:

```bash
npx adamcp profiler
```

The command binds to `127.0.0.1`, discovers live targets through the same manifests as the MCP router, and opens the dashboard. Use `--no-open`, `--port`, `--server`, or `--sessions-dir` to override the defaults. Live mode exposes bounded frame/ECS/render/display aggregates and process footprint. A frame capture records full spans for five seconds by default, persists `manifest.json`, `events.json`, `summary.json`, `capture.json`, and a Perfetto-compatible `trace.json`, then loads the trace into the embedded Perfetto UI without uploading capture data.

Agents can use `adamcp.profiler.status`, `adamcp.profiler.start`, `adamcp.profiler.stop`, `adamcp.profiler.get_report`, and `adamcp.profiler.export`. The embedded runtime also exposes the corresponding `profiler.*` tools and `ada://profiler/*` resources. Hangs, allocation stacks, symbolication, GPU counters, and Metal capture are reported as unsupported in this CPU-first increment; the dashboard does not synthesize those measurements.

The default MCP plugin records automatic engine spans on demand. Opening Live mode enables recording while snapshots are requested; it returns to idle three seconds after the last request. File sessions and profiler captures keep recording independently. Duration/frame-count captures stop without requiring another client poll, and frame counts remain valid when the bounded memory ring wraps.

For continuous history, call the runtime tool `trace.set_enabled` with `{"enabled": true}`; use `false` to return to recording on demand. This setting does not interrupt an active file session or Live consumer. `trace.status` reports the effective `recording` state and `continuousRecording` setting. Existing retained spans remain readable after recording stops. The first Live snapshot after idle may contain only earlier data until new frames complete.

Standalone recorders retain continuous recording by default; callers can configure it explicitly with `AdaMCPTraceRecorder(configuration: .init(continuousRecording: true))`. Direct `AdaMCPTracer.startSpan` calls remain explicit low-level recording operations; the demand control applies to automatic engine spans through `AdaTrace`. Spans already started finish normally when automatic recording is disabled.

## AdaUI surface

AdaUI support is intentionally inspection-first. The main flow is:

1. Locate windows or nodes.
2. Inspect the live tree and layout diagnostics.
3. Apply a limited, deterministic action.
4. Re-read the tree or diagnostics to verify the result.

External callers should target nodes by `accessibilityIdentifier`. `ui.find_nodes` can also search by `nodeType` or `viewType`, for example to locate all scroll views. `runtimeId` is returned in payloads as a session-local helper, but it is not intended to be a durable contract.
