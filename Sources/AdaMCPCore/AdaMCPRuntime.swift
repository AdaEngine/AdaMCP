import AdaEngine
import Foundation
import Logging
import MCP

public struct MCPServerConfiguration: Sendable {
    public let enableHTTP: Bool
    public let enableStdio: Bool
    public let host: String
    public let port: Int
    public let endpoint: String
    public let serverName: String
    public let serverVersion: String
    public let instructions: String?
    public let registerTypes: (@MainActor (MCPIntrospectionRegistry) -> Void)?
    public let captureOverride: RenderCaptureService.CaptureOverride?
    public let traceRecorder: AdaMCPTraceRecorder?

    public init(
        enableHTTP: Bool = true,
        enableStdio: Bool = false,
        host: String = "127.0.0.1",
        port: Int = 0,
        endpoint: String = "/mcp",
        serverName: String = "adaengine-mcp",
        serverVersion: String = "0.1.0",
        instructions: String? = "Inspect live AdaEngine worlds, entities, resources, assets, and render captures.",
        registerTypes: (@MainActor (MCPIntrospectionRegistry) -> Void)? = nil,
        captureOverride: RenderCaptureService.CaptureOverride? = nil,
        traceRecorder: AdaMCPTraceRecorder? = AdaMCPTraceRecorder()
    ) {
        self.enableHTTP = enableHTTP
        self.enableStdio = enableStdio
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.registerTypes = registerTypes
        self.captureOverride = captureOverride
        self.traceRecorder = traceRecorder
    }
}

@MainActor
public final class AdaMCPRuntime {
    let appWorlds: AppWorlds
    let registry: MCPIntrospectionRegistry
    let renderCaptureService: RenderCaptureService
    let uiInspectionService: AdaUIInspectionService
    let traceRecorder: AdaMCPTraceRecorder?
    private let logger: Logger

    public init(
        appWorlds: AppWorlds,
        registry: MCPIntrospectionRegistry,
        renderCaptureService: RenderCaptureService,
        traceRecorder: AdaMCPTraceRecorder? = nil,
        logger: Logger = Logger(label: "org.adaengine.mcp.runtime")
    ) {
        self.appWorlds = appWorlds
        self.registry = registry
        self.renderCaptureService = renderCaptureService
        self.uiInspectionService = AdaUIInspectionService(appWorlds: appWorlds)
        self.traceRecorder = traceRecorder
        self.logger = logger
    }

    public func tools() -> [Tool] {
        [
            Tool(
                name: "world.list_worlds",
                description: "List all live AdaEngine worlds.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "world.get",
                description: "Get world summary and counts.",
                inputSchema: Self.objectSchema(properties: [
                    "world": .object(["type": "string", "description": "World name, defaults to Main"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "entity.get_by_id",
                description: "Get one entity by numeric identifier.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "world": .object(["type": "string"]),
                        "id": .object(["type": "integer"])
                    ],
                    required: ["id"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "entity.get_by_name",
                description: "Get one entity by exact name.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "world": .object(["type": "string"]),
                        "name": .object(["type": "string"])
                    ],
                    required: ["name"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "entity.find",
                description: "Find entities by name, active state, or component type.",
                inputSchema: Self.objectSchema(properties: [
                    "world": .object(["type": "string"]),
                    "name": .object(["type": "string"]),
                    "active": .object(["type": "boolean"]),
                    "componentType": .object(["type": "string"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "entity.list_components",
                description: "List inspectable components for an entity.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "world": .object(["type": "string"]),
                        "entityId": .object(["type": "integer"])
                    ],
                    required: ["entityId"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "component.get",
                description: "Get one component payload by entity and type name.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "world": .object(["type": "string"]),
                        "entityId": .object(["type": "integer"]),
                        "componentType": .object(["type": "string"])
                    ],
                    required: ["entityId", "componentType"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "resource.list",
                description: "List inspectable resources for a world.",
                inputSchema: Self.objectSchema(properties: [
                    "world": .object(["type": "string"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "resource.get",
                description: "Get one resource payload by type name.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "world": .object(["type": "string"]),
                        "resourceType": .object(["type": "string"])
                    ],
                    required: ["resourceType"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "asset.find",
                description: "Find cached asset info by path, name, type, or asset ID.",
                inputSchema: Self.objectSchema(properties: [
                    "path": .object(["type": "string"]),
                    "name": .object(["type": "string"]),
                    "type": .object(["type": "string"]),
                    "assetId": .object(["type": "string"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "asset.get",
                description: "Get one cached asset info record.",
                inputSchema: Self.objectSchema(properties: [
                    "path": .object(["type": "string"]),
                    "name": .object(["type": "string"]),
                    "type": .object(["type": "string"]),
                    "assetId": .object(["type": "string"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "runtime.pause",
                description: "Pause AdaEngine simulation updates.",
                inputSchema: Self.objectSchema(properties: [
                    "reason": .object(["type": "string"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "runtime.resume",
                description: "Resume AdaEngine simulation updates.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "runtime.step_frame",
                description: "Advance one or more paused simulation frames immediately.",
                inputSchema: Self.objectSchema(properties: [
                    "frames": .object(["type": "integer"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "render.capture_screenshot",
                description: "Pause if needed, render a frame, and save a PNG screenshot.",
                inputSchema: Self.objectSchema(properties: [
                    "cameraEntityId": .object(["type": "integer"]),
                    "cameraName": .object(["type": "string"]),
                    "pauseBeforeCapture": .object(["type": "boolean"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "trace.list_spans",
                description: "List finished AdaEngine tracing spans captured by AdaMCP.",
                inputSchema: Self.objectSchema(properties: [
                    "traceId": .object(["type": "string"]),
                    "nameContains": .object(["type": "string"]),
                    "limit": .object(["type": "integer"]),
                    "clearAfterRead": .object(["type": "boolean"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "trace.export_otlp",
                description: "Export finished AdaEngine tracing spans as OpenTelemetry OTLP JSON.",
                inputSchema: Self.objectSchema(properties: [
                    "traceId": .object(["type": "string"]),
                    "nameContains": .object(["type": "string"]),
                    "limit": .object(["type": "integer"]),
                    "clearAfterExport": .object(["type": "boolean"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "trace.clear",
                description: "Clear finished tracing spans captured by AdaMCP.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.list_windows",
                description: "List live AdaUI windows.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.get_window",
                description: "Get one AdaUI window snapshot and its root view trees.",
                inputSchema: Self.objectSchema(properties: [
                    "windowId": .object(["type": "integer"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.get_tree",
                description: "Get one AdaUI window tree snapshot.",
                inputSchema: Self.objectSchema(properties: [
                    "windowId": .object(["type": "integer"])
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.get_node",
                description: "Get one AdaUI node by accessibility identifier or runtime ID.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"])
                    ]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.find_nodes",
                description: "Find AdaUI nodes by accessibility identifier, runtime ID, node type, or view type.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"]),
                        "nodeType": .object(["type": "string"]),
                        "viewType": .object(["type": "string"])
                    ]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.capture_node_screenshot",
                description: "Capture the current render output and save a PNG cropped to a selected AdaUI node.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"]),
                        "nodeType": .object(["type": "string"]),
                        "viewType": .object(["type": "string"]),
                        "cameraEntityId": .object(["type": "integer"]),
                        "cameraName": .object(["type": "string"]),
                        "pauseBeforeCapture": .object(["type": "boolean"]),
                        "padding": .object(["type": "number"])
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "ui.hit_test",
                description: "Resolve the deepest AdaUI node at window coordinates.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "x": .object(["type": "number"]),
                        "y": .object(["type": "number"])
                    ],
                    required: ["x", "y"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.get_layout_diagnostics",
                description: "Get layout diagnostics for a window or target node.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"]),
                        "subtreeDepth": .object(["type": "integer"])
                    ]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.set_debug_overlay",
                description: "Enable or disable AdaUI debug overlay drawing.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "mode": .object([
                            "type": "string",
                            "enum": .array([
                                .string(UIDebugOverlayMode.off.rawValue),
                                .string(UIDebugOverlayMode.layoutBounds.rawValue),
                                .string(UIDebugOverlayMode.focusedNode.rawValue),
                                .string(UIDebugOverlayMode.hitTestTarget.rawValue)
                            ])
                        ])
                    ],
                    required: ["mode"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.focus_node",
                description: "Move AdaUI focus to a specific node.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"])
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ui.focus_next",
                description: "Move AdaUI focus to the next focusable node.",
                inputSchema: Self.objectSchema(properties: [
                    "windowId": .object(["type": "integer"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "ui.focus_previous",
                description: "Move AdaUI focus to the previous focusable node.",
                inputSchema: Self.objectSchema(properties: [
                    "windowId": .object(["type": "integer"])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "ui.scroll_to_node",
                description: "Scroll the nearest AdaUI scroll container to a target node.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"])
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "ui.tap_node",
                description: "Perform a deterministic tap/click on a target AdaUI node.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "windowId": .object(["type": "integer"]),
                        "accessibilityIdentifier": .object(["type": "string"]),
                        "runtimeId": .object(["type": "string"])
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            )
        ]
    }

    public func resources() -> [MCP.Resource] {
        var resources = [
            MCP.Resource(
                name: "World List",
                uri: "ada://worlds",
                description: "Live world index.",
                mimeType: "application/json"
            ),
            MCP.Resource(
                name: "Inspectable Component Types",
                uri: "ada://types/components",
                description: "Registered inspectable component descriptors.",
                mimeType: "application/json"
            ),
            MCP.Resource(
                name: "Inspectable Resource Types",
                uri: "ada://types/resources",
                description: "Registered inspectable resource descriptors.",
                mimeType: "application/json"
            ),
            MCP.Resource(
                name: "Inspectable Asset Types",
                uri: "ada://types/assets",
                description: "Registered inspectable asset descriptors.",
                mimeType: "application/json"
            ),
            MCP.Resource(
                name: "UI Windows",
                uri: "ada://ui/windows",
                description: "Live AdaUI window index.",
                mimeType: "application/json"
            ),
            MCP.Resource(
                name: "Trace Spans",
                uri: "ada://traces/spans",
                description: "Finished AdaEngine tracing spans captured by AdaMCP.",
                mimeType: "application/json"
            ),
            MCP.Resource(
                name: "Trace OTLP Export",
                uri: "ada://traces/otlp",
                description: "Finished AdaEngine tracing spans as OpenTelemetry OTLP JSON.",
                mimeType: "application/json"
            )
        ]

        for worldName in appWorlds.allWorldNames().map(\.rawValue).sorted() {
            resources.append(
                MCP.Resource(
                    name: "\(worldName) World Snapshot",
                    uri: "ada://world/\(worldName)",
                    description: "Snapshot of the \(worldName) world.",
                    mimeType: "application/json"
                )
            )
        }

        for window in uiInspectionService.listWindows() {
            resources.append(
                MCP.Resource(
                    name: "UI Window \(window.windowId)",
                    uri: "ada://ui/window/\(window.windowId)",
                    description: "Snapshot of AdaUI window \(window.windowId).",
                    mimeType: "application/json"
                )
            )
            resources.append(
                MCP.Resource(
                    name: "UI Tree \(window.windowId)",
                    uri: "ada://ui/tree/\(window.windowId)",
                    description: "Root AdaUI tree snapshot for window \(window.windowId).",
                    mimeType: "application/json"
                )
            )
        }

        return resources
    }

    public func resourceTemplates() -> [MCP.Resource.Template] {
        [
            MCP.Resource.Template(
                uriTemplate: "ada://entity/{world}/{id}",
                name: "Entity Snapshot",
                title: "Entity Snapshot",
                description: "Entity snapshot by world name and entity identifier.",
                mimeType: "application/json"
            ),
            MCP.Resource.Template(
                uriTemplate: "ada://ui/window/{windowId}",
                name: "UI Window Snapshot",
                title: "UI Window Snapshot",
                description: "AdaUI window snapshot by window identifier.",
                mimeType: "application/json"
            ),
            MCP.Resource.Template(
                uriTemplate: "ada://ui/tree/{windowId}",
                name: "UI Tree Snapshot",
                title: "UI Tree Snapshot",
                description: "AdaUI root tree snapshot by window identifier.",
                mimeType: "application/json"
            ),
            MCP.Resource.Template(
                uriTemplate: "ada://ui/node/{windowId}/{nodeRef}",
                name: "UI Node Snapshot",
                title: "UI Node Snapshot",
                description: "AdaUI node snapshot by window identifier and node selector.",
                mimeType: "application/json"
            ),
            MCP.Resource.Template(
                uriTemplate: "ada://traces/{format}",
                name: "Trace Export",
                title: "Trace Export",
                description: "Trace export by format: spans or otlp.",
                mimeType: "application/json"
            )
        ]
    }

    public func callTool(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let payload: Value
            switch name {
            case "world.list_worlds":
                payload = try self.listWorldsPayload()
            case "world.get":
                payload = try self.worldPayload(named: arguments["world"]?.stringValue)
            case "entity.get_by_id":
                payload = try self.entityByIDPayload(arguments: arguments)
            case "entity.get_by_name":
                payload = try self.entityByNamePayload(arguments: arguments)
            case "entity.find":
                payload = try self.findEntitiesPayload(arguments: arguments)
            case "entity.list_components":
                payload = try self.entityComponentsPayload(arguments: arguments)
            case "component.get":
                payload = try self.componentPayload(arguments: arguments)
            case "resource.list":
                payload = try self.listResourcesPayload(arguments: arguments)
            case "resource.get":
                payload = try self.resourcePayload(arguments: arguments)
            case "asset.find":
                payload = try await self.assetFindPayload(arguments: arguments)
            case "asset.get":
                payload = try await self.assetGetPayload(arguments: arguments)
            case "runtime.pause":
                payload = try self.pausePayload(reason: arguments["reason"]?.stringValue)
            case "runtime.resume":
                payload = try self.resumePayload()
            case "runtime.step_frame":
                payload = try await self.stepFramePayload(frames: arguments["frames"]?.intValue ?? 1)
            case "render.capture_screenshot":
                payload = try await self.captureScreenshotPayload(arguments: arguments)
            case "trace.list_spans":
                payload = try self.traceSpansPayload(arguments: arguments)
            case "trace.export_otlp":
                payload = try self.traceOTLPPayload(arguments: arguments)
            case "trace.clear":
                payload = try self.traceClearPayload()
            case "ui.list_windows":
                payload = try self.uiListWindowsPayload()
            case "ui.get_window":
                payload = try self.uiGetWindowPayload(arguments: arguments)
            case "ui.get_tree":
                payload = try self.uiGetTreePayload(arguments: arguments)
            case "ui.get_node":
                payload = try self.uiGetNodePayload(arguments: arguments)
            case "ui.find_nodes":
                payload = try self.uiFindNodesPayload(arguments: arguments)
            case "ui.capture_node_screenshot":
                payload = try await self.uiCaptureNodeScreenshotPayload(arguments: arguments)
            case "ui.hit_test":
                payload = try self.uiHitTestPayload(arguments: arguments)
            case "ui.get_layout_diagnostics":
                payload = try self.uiLayoutDiagnosticsPayload(arguments: arguments)
            case "ui.set_debug_overlay":
                payload = try self.uiSetDebugOverlayPayload(arguments: arguments)
            case "ui.focus_node":
                payload = try self.uiFocusNodePayload(arguments: arguments)
            case "ui.focus_next":
                payload = try self.uiFocusNextPayload(arguments: arguments)
            case "ui.focus_previous":
                payload = try self.uiFocusPreviousPayload(arguments: arguments)
            case "ui.scroll_to_node":
                payload = try self.uiScrollToNodePayload(arguments: arguments)
            case "ui.tap_node":
                payload = try self.uiTapNodePayload(arguments: arguments)
            default:
                return .init(content: [.text(text: "Unknown MCP tool '\(name)'.", annotations: nil, _meta: nil)], isError: true)
            }

            return try self.jsonToolResult(payload)
        } catch {
            if let mcpError = error as? AdaMCPError {
                return (try? self.jsonToolResult(Value(mcpError.payload), isError: true))
                    ?? .init(content: [.text(text: mcpError.localizedDescription, annotations: nil, _meta: nil)], isError: true)
            }

            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    public func readResource(uri: String) async throws -> ReadResource.Result {
        let payload: Value
        guard let url = URL(string: uri), url.scheme == "ada" else {
            throw AdaMCPError.invalidResourceURI(uri)
        }

        switch url.host {
        case "worlds":
            payload = try self.listWorldsPayload()
        case "world":
            let worldName = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            payload = try self.worldPayload(named: worldName)
        case "entity":
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 2, let entityID = Int(parts[1]) else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            payload = try self.entityPayload(worldName: parts[0], entityID: entityID)
        case "types":
            let kind = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            payload = try self.typeListPayload(kind: kind)
        case "ui":
            payload = try self.uiResourcePayload(url: url, uri: uri)
        case "traces":
            payload = try self.traceResourcePayload(url: url, uri: uri)
        default:
            throw AdaMCPError.invalidResourceURI(uri)
        }

        return try self.jsonResourceResult(payload, uri: uri)
    }

    private static func objectSchema(
        properties: [String: Value] = [:],
        required: [String] = []
    ) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(Value.string))
        }
        return .object(schema)
    }

    private func jsonToolResult(_ payload: Value, isError: Bool = false) throws -> CallTool.Result {
        let text = try self.prettyJSONString(payload)
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }

    private func jsonResourceResult(_ payload: Value, uri: String) throws -> ReadResource.Result {
        let text = try self.prettyJSONString(payload)
        return .init(contents: [.text(text, uri: uri, mimeType: "application/json")])
    }

    private func prettyJSONString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

}
