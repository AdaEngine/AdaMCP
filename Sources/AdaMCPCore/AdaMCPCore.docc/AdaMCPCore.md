# ``AdaMCPCore``

`AdaMCPCore` turns a live AdaEngine application into an inspection-friendly MCP runtime.

## Overview

Use `AdaMCPCore` when you need to expose live engine state to tools, agents, or external automation:

- Inspect worlds, entities, components, resources, and assets.
- Capture render output for visual verification.
- Inspect AdaUI windows and view trees, including node lookup by accessibility identifier, runtime ID, node type, or view type.
- Capture a screenshot cropped to the visible bounds of a selected AdaUI node.
- Run a small, deterministic set of AdaUI actions such as focus traversal, scrolling, and tapping a resolved node.

`AdaMCP` is transport-agnostic at the runtime layer. `AdaMCPServer` handles MCP server wiring, while `AdaMCPPlugin` embeds the runtime inside an AdaEngine app.

## AdaUI inspection highlights

Use `ui.find_nodes` to locate live AdaUI nodes. It accepts `accessibilityIdentifier`, `runtimeId`, `nodeType`, or `viewType`; type queries use case-insensitive substring matching, so `nodeType: "ScrollView"` can find scroll view nodes.

Use `ui.capture_node_screenshot` when an agent needs visual context for one UI element instead of the whole render target. The tool resolves a unique node, captures the current render output, crops the PNG to the node's visible frame, and returns both the source screenshot metadata and the cropped image path.

## Topics

### Essentials

- <doc:Getting-Started-With-AdaMCP>
- <doc:AdaUI-Inspection-and-Automation>

### Core types

- ``AdaMCPRuntime``
- ``MCPServerConfiguration``
- ``RenderCaptureService``
