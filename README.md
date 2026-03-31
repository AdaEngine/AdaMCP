# AdaMCP - MCP Server for AdaEngine

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAdaEngine%2FAdaMCP%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/AdaEngine/AdaMCP)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAdaEngine%2FAdaMCP%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/AdaEngine/AdaMCP)

`AdaMCP` exposes a live AdaEngine application as an MCP server. It is built for inspection-first workflows: world/entity/resource introspection, render capture, and AdaUI tree inspection with a small set of safe UI actions.

## Current platform support 

The important distinction is:

- MCP clients can live anywhere and connect over HTTP or stdio.
- The host runtime now builds on the broader Apple surface, while `stdio` remains primarily a local host transport and HTTP is the main cross-device option.

## What you get 🌸

- 😳 World, entity, component, resource, and asset inspection.
- 📸 Screenshot capture for live render output.
- 💉 AdaUI inspection tools such as `ui.list_windows`, `ui.get_tree`, `ui.get_node`, `ui.find_nodes`, and `ui.hit_test`.
- 🧑‍🏫 AdaUI diagnostics and safe actions such as focus traversal, deterministic tap, and scroll-to-node.
- 📦 MCP resources under `ada://...`, including `ada://ui/windows`, `ada://ui/window/{id}`, `ada://ui/tree/{id}`, and `ada://ui/node/{windowId}/{nodeRef}`.

## Embedding in an AdaEngine app ⚒️

Until the package is published, add it as a local SwiftPM dependency:

```swift
dependencies: [
    .package(url: "https://github.com/AdaEngine/AdaMCP.git", branch: "main")
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

## AdaUI surface

AdaUI support is intentionally inspection-first. The main flow is:

1. Locate windows or nodes.
2. Inspect the live tree and layout diagnostics.
3. Apply a limited, deterministic action.
4. Re-read the tree or diagnostics to verify the result.

External callers should target nodes by `accessibilityIdentifier`. `runtimeId` is returned in payloads as a session-local helper, but it is not intended to be a durable contract.

## Documentation

- [DocC landing page](./Sources/AdaMCPCore/AdaMCPCore.docc/AdaMCPCore.md)
- [Getting Started With AdaMCP](./Sources/AdaMCPCore/AdaMCPCore.docc/Getting-Started-With-AdaMCP.md)
- [AdaUI Inspection and Automation](./Sources/AdaMCPCore/AdaMCPCore.docc/AdaUI-Inspection-and-Automation.md)
