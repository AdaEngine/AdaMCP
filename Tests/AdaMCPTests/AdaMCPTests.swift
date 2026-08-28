@_spi(Internal) import AdaEngine
import AdaMCPCore
import AdaMCPServer
import Foundation
import InMemoryTracing
import MCP
import Testing
import Tracing

@preconcurrency import SystemPackage

@MainActor
@Suite("AdaMCP Tests")
struct AdaMCPTests {
    struct InspectableSettings: Codable, Sendable, AdaEngine.Resource {
        var label: String
    }

    struct HiddenResource: Sendable, AdaEngine.Resource {
        var token: Int
    }

    struct HiddenComponent: Sendable, Component {
        var token: Int
    }

    @MainActor
    final class UITapRecorder {
        var tapCount = 0
    }

    @MainActor
    final class TestWindowManager: UIWindowManager {
        private var cursorShape: Input.CursorShape = .arrow
        private var mouseMode: Input.MouseMode = .visible

        override func showWindow(_ window: UIWindow, isFocused: Bool) {
            if isFocused {
                self.setActiveWindow(window)
            }
            window.windowDidAppear()
        }

        override func closeWindow(_ window: UIWindow) { }

        override func setWindowMode(_ window: UIWindow, mode: UIWindow.Mode) {
            window.isFullscreen = (mode == .fullscreen)
        }

        override func setMinimumSize(_ size: Size, for window: UIWindow) { }

        override func resizeWindow(_ window: UIWindow, size: Size) { }

        override func getScreen(for window: UIWindow) -> Screen? {
            nil
        }

        override func setCursorShape(_ shape: Input.CursorShape) {
            self.cursorShape = shape
        }

        override func getCursorShape() -> Input.CursorShape {
            self.cursorShape
        }

        override func setCursorImage(for shape: Input.CursorShape, texture: Texture2D?, hotspot: Vector2) { }

        override func setMouseMode(_ mode: Input.MouseMode) {
            self.mouseMode = mode
        }

        override func getMouseMode() -> Input.MouseMode {
            self.mouseMode
        }

        override func updateCursor() { }
    }

    @MainActor
    struct UITestRootView: View {
        let recorder: UITapRecorder

        var body: some View {
            ScrollView {
                VStack(spacing: 12) {
                    Button(action: { }) {
                        Divider().frame(width: 140, height: 18)
                    }
                    .accessibilityIdentifier("button.first")
                    Button(action: { }) {
                        Divider().frame(width: 140, height: 18)
                    }
                    .accessibilityIdentifier("button.second")
                    Divider()
                        .frame(height: 320)
                        .accessibilityIdentifier("spacer.large")
                    Button(action: {
                        recorder.tapCount += 1
                    }) {
                        Divider().frame(width: 140, height: 18)
                    }
                    .accessibilityIdentifier("button.tap")
                    Button(action: { }) {
                        Divider().frame(width: 100, height: 14)
                    }
                        .accessibilityIdentifier("duplicate.node")
                    Button(action: { }) {
                        Divider().frame(width: 100, height: 14)
                    }
                        .accessibilityIdentifier("duplicate.node")
                }
            }
            .frame(width: 220, height: 140)
            .accessibilityIdentifier("scroll.root")
        }
    }

    @Test("Registry registers and serializes codable types")
    func registryRegistersAndSerializesCodableTypes() throws {
        let registry = MCPIntrospectionRegistry()
        registry.registerCodable(
            InspectableSettings.self,
            kind: .resource,
            fields: [.init(name: "label", typeName: "String")]
        )

        let descriptor = try #require(registry.descriptor(named: String(reflecting: InspectableSettings.self)))
        #expect(descriptor.kind == .resource)
        #expect(descriptor.serialization == .codable)

        let serialized = try #require(try registry.serialize(InspectableSettings(label: "debug")))
        #expect(serialized.objectValue?["label"]?.stringValue == "debug")
    }

    @Test("Runtime inspects entities, resources, and screenshots")
    func runtimeInspectsEntitiesResourcesAndScreenshots() async throws {
        let fixture = self.makeFixture()

        let entityResult = await fixture.runtime.callTool(
            name: "entity.get_by_name",
            arguments: ["name": .string("Player")]
        )
        let entityPayload = try self.decodeToolPayload(entityResult)
        #expect(entityPayload.objectValue?["name"]?.stringValue == "Player")
        #expect(entityPayload.objectValue?["world"]?.stringValue == AppWorldName.main.rawValue)

        let components = entityPayload.objectValue?["components"]?.arrayValue ?? []
        #expect(
            components.contains {
                $0.objectValue?["type"]?.stringValue == String(reflecting: Transform.self)
            }
        )

        let diagnostics = entityPayload.objectValue?["diagnostics"]?.arrayValue ?? []
        #expect(diagnostics.count == 2)

        let componentResult = await fixture.runtime.callTool(
            name: "component.get",
            arguments: [
                "entityId": .int(fixture.player.id),
                "componentType": .string(String(reflecting: Transform.self))
            ]
        )
        let componentPayload = try self.decodeToolPayload(componentResult)
        #expect(componentPayload.objectValue?["type"]?.stringValue == String(reflecting: Transform.self))

        let resourceResult = await fixture.runtime.callTool(name: "resource.list", arguments: [:])
        let resourcePayload = try self.decodeToolPayload(resourceResult)
        let resources = resourcePayload.objectValue?["resources"]?.arrayValue ?? []
        #expect(
            resources.contains {
                $0.objectValue?["type"]?.stringValue == String(reflecting: InspectableSettings.self)
            }
        )
        let resourceDiagnostics = resourcePayload.objectValue?["diagnostics"]?.arrayValue ?? []
        #expect(resourceDiagnostics.count == 1)

        let screenshotResult = await fixture.runtime.callTool(
            name: "render.capture_screenshot",
            arguments: ["cameraName": .string("Primary")]
        )
        let screenshotPayload = try self.decodeToolPayload(screenshotResult)
        #expect(screenshotPayload.objectValue?["path"]?.stringValue == "/tmp/adamcp-test.png")
        #expect(screenshotPayload.objectValue?["cameraName"]?.stringValue == "Primary")
    }

    @Test("Server exposes tools, resources, and templates over MCP")
    func serverExposesToolsResourcesAndTemplates() async throws {
        let fixture = self.makeFixture()
        let server = await AdaMCPServerFactory.makeServer(
            runtime: fixture.runtime,
            configuration: MCPServerConfiguration(
                serverName: "adamcp-tests",
                serverVersion: "1.0.0"
            )
        )

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "AdaMCPTests", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let (tools, _) = try await client.listTools()
        #expect(tools.contains { $0.name == "entity.get_by_name" })
        #expect(tools.contains { $0.name == "render.capture_screenshot" })
        #expect(tools.contains { $0.name == "render_graph.get" })
        #expect(tools.contains { $0.name == "render_graph.collect_frames" })
        #expect(tools.contains { $0.name == "render_graph.dump_attachment" })
        #expect(tools.contains { $0.name == "profiler.capabilities" })
        #expect(tools.contains { $0.name == "profiler.live_snapshot" })
        #expect(tools.contains { $0.name == "profiler.start_capture" })
        #expect(tools.contains { $0.name == "profiler.stop_capture" })
        #expect(tools.contains { $0.name == "profiler.get_capture" })

        let (resources, _) = try await client.listResources()
        #expect(resources.contains { $0.uri == "ada://worlds" })
        #expect(resources.contains { $0.uri == "ada://world/Main" })
        #expect(resources.contains { $0.uri == "ada://render/graphs" })
        #expect(resources.contains { $0.uri == "ada://render/frames/recent" })
        #expect(resources.contains { $0.uri == "ada://render/cameras" })
        #expect(resources.contains { $0.uri == "ada://profiler/live" })
        #expect(resources.contains { $0.uri == "ada://profiler/captures" })

        let (templates, _) = try await client.listResourceTemplates()
        #expect(templates.contains { $0.uriTemplate == "ada://entity/{world}/{id}" })
        #expect(templates.contains { $0.uriTemplate == "ada://render/graph/{label}" })
        #expect(templates.contains { $0.uriTemplate == "ada://profiler/capture/{id}" })

        let worldContents = try await client.readResource(uri: "ada://worlds")
        let worldsPayload = try self.decodeResourcePayload(worldContents)
        let worlds = worldsPayload.objectValue?["worlds"]?.arrayValue ?? []
        #expect(worlds.isEmpty == false)

        let componentCall = try await client.callTool(
            name: "component.get",
            arguments: [
                "entityId": .int(fixture.player.id),
                "componentType": .string(String(reflecting: Transform.self))
            ]
        )
        let componentPayload = try self.decodeToolPayload(componentCall.content)
        #expect(componentPayload.objectValue?["type"]?.stringValue == String(reflecting: Transform.self))

        await client.disconnect()
        await server.stop()
        await clientTransport.disconnect()
        await serverTransport.disconnect()
    }

    @Test("Runtime exposes render graph diagnostics")
    func runtimeExposesRenderGraphDiagnostics() async throws {
        let fixture = try await self.makeRenderGraphFixture()

        let getResult = await fixture.runtime.callTool(
            name: "render_graph.get",
            arguments: ["includeSubgraphs": .bool(true)]
        )
        let getPayload = try self.decodeToolPayload(getResult)
        #expect(getPayload.objectValue?["backend"]?.objectValue?["type"]?.stringValue == "unknown")
        #expect(getPayload.objectValue?["graph"]?.objectValue?["label"]?.stringValue == "Root Graph")

        let cameras = getPayload.objectValue?["cameras"]?.arrayValue ?? []
        #expect(cameras.count == 1)
        #expect(cameras.first?.objectValue?["name"]?.stringValue == "Primary Camera")
        let attachments = cameras.first?.objectValue?["attachments"]?.arrayValue ?? []
        #expect(
            attachments.contains {
                $0.objectValue?["name"]?.stringValue == "depth"
                    && $0.objectValue?["isAvailable"]?.boolValue == false
                    && $0.objectValue?["unsupportedReason"]?.stringValue != nil
            }
        )

        let graphsPayload = try self.decodeResourcePayload(
            try await fixture.runtime.readResource(uri: "ada://render/graphs").contents
        )
        #expect(graphsPayload.objectValue?["graph"]?.objectValue?["label"]?.stringValue == "Root Graph")

        let subgraphPayload = try self.decodeResourcePayload(
            try await fixture.runtime.readResource(uri: "ada://render/graph/Sub%20Graph%20A").contents
        )
        #expect(subgraphPayload.objectValue?["label"]?.stringValue == "Sub Graph A")

        let camerasPayload = try self.decodeResourcePayload(
            try await fixture.runtime.readResource(uri: "ada://render/cameras").contents
        )
        #expect(camerasPayload.arrayValue?.first?.objectValue?["entityId"]?.intValue == fixture.camera.id)

        let collectResult = await fixture.runtime.callTool(
            name: "render_graph.collect_frames",
            arguments: [
                "frames": .int(2),
                "pauseBeforeCapture": .bool(true),
                "clearBeforeCollect": .bool(true)
            ]
        )
        let collectPayload = try self.decodeToolPayload(collectResult)
        #expect(collectPayload.objectValue?["requestedFrames"]?.intValue == 2)
        let records = collectPayload.objectValue?["records"]?.arrayValue ?? []
        #expect(records.count == 4)
        #expect(records.contains { $0.objectValue?["graphLabel"]?.stringValue == "Root Graph" })
        #expect(records.contains { $0.objectValue?["graphLabel"]?.stringValue == "Sub Graph A" })
        #expect(fixture.diagnostics.isEnabled == false)
        #expect(fixture.diagnostics.capacity == 2)

        let control = fixture.appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        #expect(control.wrappedValue.mode == .paused)
        #expect(control.wrappedValue.reason == "before collect")
        #expect(control.wrappedValue.pendingStepCount == 5)

        let recentFramesPayload = try self.decodeResourcePayload(
            try await fixture.runtime.readResource(uri: "ada://render/frames/recent").contents
        )
        #expect(recentFramesPayload.arrayValue?.count == 2)

        let depthDumpResult = await fixture.runtime.callTool(
            name: "render_graph.dump_attachment",
            arguments: [
                "cameraName": .string("Primary Camera"),
                "attachment": .string("depth"),
                "pauseBeforeCapture": .bool(false),
                "refreshFrame": .bool(false)
            ]
        )
        let depthDumpPayload = try self.decodeToolPayload(depthDumpResult)
        #expect(depthDumpPayload.objectValue?["isDumped"]?.boolValue == false)
        #expect(depthDumpPayload.objectValue?["attachment"]?.objectValue?["name"]?.stringValue == "depth")
        #expect(depthDumpPayload.objectValue?["unsupportedReason"]?.stringValue != nil)
    }

    @Test("Server supports stdio transport roundtrip")
    func serverSupportsStdioTransportRoundtrip() async throws {
        #if os(Windows)
        // Windows anonymous pipes can block this in-process stdio loop under Swift Testing.
        // The production stdio transport still builds on Windows; HTTP is the cross-platform embedded path.
        return
        #else
        let fixture = self.makeFixture()
        let server = await AdaMCPServerFactory.makeServer(
            runtime: fixture.runtime,
            configuration: MCPServerConfiguration(
                enableHTTP: false,
                enableStdio: true,
                serverName: "adamcp-stdio-tests",
                serverVersion: "1.0.0"
            )
        )

        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()
        let serverTransport = StdioTransport(
            input: clientToServerRead,
            output: serverToClientWrite,
            logger: nil
        )
        let clientTransport = StdioTransport(
            input: serverToClientRead,
            output: clientToServerWrite,
            logger: nil
        )
        let client = Client(name: "AdaMCPTests", version: "1.0.0")

        try await server.start(transport: serverTransport)
        _ = try await client.connect(transport: clientTransport)

        let (templates, _) = try await client.listResourceTemplates()
        #expect(templates.contains { $0.uriTemplate == "ada://entity/{world}/{id}" })

        let entityContents = try await client.readResource(uri: "ada://entity/Main/\(fixture.player.id)")
        let entityPayload = try self.decodeResourcePayload(entityContents)
        #expect(entityPayload.objectValue?["name"]?.stringValue == "Player")
        #expect(entityPayload.objectValue?["id"]?.intValue == fixture.player.id)

        await client.disconnect()
        await server.stop()
        try? clientToServerRead.close()
        try? clientToServerWrite.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
        #endif
    }

    @Test("Runtime exports captured tracing spans as OTLP JSON")
    func runtimeExportsTracingSpansAsOTLPJSON() async throws {
        let recorder = AdaMCPTraceRecorder(
            tracer: AdaMCPTracer(idGenerator: .incrementing),
            serviceName: "adamcp-tests",
            scopeName: "AdaMCPTests"
        )
        let span = recorder.tracer.startSpan("AppWorlds.update")
        span.attributes["world.name"] = "Main"
        span.addEvent("scheduler.started")
        span.end()

        let fixture = self.makeFixture(traceRecorder: recorder)

        let spansResult = await fixture.runtime.callTool(name: "trace.list_spans", arguments: [:])
        let spansPayload = try self.decodeToolPayload(spansResult)
        let spans = spansPayload.objectValue?["spans"]?.arrayValue ?? []
        #expect(spans.count == 1)
        #expect(spans.first?.objectValue?["name"]?.stringValue == "AppWorlds.update")
        #expect(spans.first?.objectValue?["attributes"]?.objectValue?["world.name"]?.stringValue == "Main")

        let otlpResult = await fixture.runtime.callTool(name: "trace.export_otlp", arguments: [:])
        let otlpPayload = try self.decodeToolPayload(otlpResult)
        let resourceSpans = otlpPayload.objectValue?["resourceSpans"]?.arrayValue ?? []
        let scopeSpans = resourceSpans.first?.objectValue?["scopeSpans"]?.arrayValue ?? []
        let otlpSpans = scopeSpans.first?.objectValue?["spans"]?.arrayValue ?? []
        let otlpSpan = try #require(otlpSpans.first?.objectValue)
        #expect(otlpSpan["name"]?.stringValue == "AppWorlds.update")
        #expect(otlpSpan["kind"]?.stringValue == "SPAN_KIND_INTERNAL")
        #expect(otlpSpan["traceId"]?.stringValue == "trace-1")
        #expect(otlpSpan["spanId"]?.stringValue == "span-1")

        let attributes = otlpSpan["attributes"]?.arrayValue ?? []
        #expect(
            attributes.contains {
                $0.objectValue?["key"]?.stringValue == "world.name"
                    && $0.objectValue?["value"]?.objectValue?["stringValue"]?.stringValue == "Main"
            }
        )

        let events = otlpSpan["events"]?.arrayValue ?? []
        #expect(events.first?.objectValue?["name"]?.stringValue == "scheduler.started")
    }

    @Test("Runtime keeps only the newest bounded tracing spans")
    func runtimeKeepsOnlyNewestBoundedTracingSpans() async throws {
        let recorder = AdaMCPTraceRecorder(
            tracer: AdaMCPTracer(idGenerator: .incrementing, maxFinishedSpanCount: 2),
            serviceName: "adamcp-tests",
            scopeName: "AdaMCPTests"
        )
        for name in ["first", "second", "third"] {
            let span = recorder.tracer.startSpan(name)
            span.end()
        }

        let fixture = self.makeFixture(traceRecorder: recorder)
        let spansResult = await fixture.runtime.callTool(name: "trace.list_spans", arguments: [:])
        let spansPayload = try self.decodeToolPayload(spansResult)
        let spans = spansPayload.objectValue?["spans"]?.arrayValue ?? []
        #expect(spans.map { $0.objectValue?["name"]?.stringValue } == ["second", "third"])

        let summary = spansPayload.objectValue?["summary"]?.objectValue
        #expect(summary?["finishedSpanCount"]?.intValue == 2)
        #expect(summary?["droppedSpanCount"]?.intValue == 1)
        #expect(summary?["maxFinishedSpanCount"]?.intValue == 2)

        let clearResult = await fixture.runtime.callTool(name: "trace.clear", arguments: [:])
        _ = try self.decodeToolPayload(clearResult)

        let statusResult = await fixture.runtime.callTool(name: "trace.status", arguments: [:])
        let statusPayload = try self.decodeToolPayload(statusResult)
        let memory = statusPayload.objectValue?["memory"]?.objectValue
        #expect(memory?["finishedSpanCount"]?.intValue == 0)
        #expect(memory?["droppedSpanCount"]?.intValue == 0)
    }

    @Test("Runtime records file tracing sessions on demand and deletes exported files")
    func runtimeRecordsFileTracingSessionsOnDemandAndDeletesExportedFiles() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaMCPTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let recorder = AdaMCPTraceRecorder(
            tracer: AdaMCPTracer(
                idGenerator: .incrementing,
                maxFinishedSpanCount: 10,
                temporaryDirectory: temporaryDirectory
            ),
            serviceName: "adamcp-tests",
            scopeName: "AdaMCPTests"
        )
        let fixture = self.makeFixture(traceRecorder: recorder)

        let beforeStartSpan = recorder.tracer.startSpan("before-start")
        beforeStartSpan.end()

        let initialStatusResult = await fixture.runtime.callTool(name: "trace.status", arguments: [:])
        let initialStatusPayload = try self.decodeToolPayload(initialStatusResult)
        #expect(initialStatusPayload.objectValue?["fileSession"]?.objectValue?["active"]?.boolValue == false)
        #expect(initialStatusPayload.objectValue?["fileSession"]?.objectValue?["path"] == .null)
        #expect(FileManager.default.fileExists(atPath: temporaryDirectory.path) == false)

        let startResult = await fixture.runtime.callTool(name: "trace.start_file", arguments: [:])
        let startPayload = try self.decodeToolPayload(startResult)
        let filePath = try #require(startPayload.objectValue?["fileSession"]?.objectValue?["path"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: filePath))

        let doubleStartResult = await fixture.runtime.callTool(name: "trace.start_file", arguments: [:])
        #expect(doubleStartResult.isError == true)
        let doubleStartPayload = try self.decodeToolPayload(doubleStartResult)
        #expect(doubleStartPayload.objectValue?["code"]?.stringValue == "trace_file_session_already_active")

        let afterStartSpan = recorder.tracer.startSpan("after-start")
        afterStartSpan.attributes["phase"] = "file"
        afterStartSpan.end()

        let stopResult = await fixture.runtime.callTool(name: "trace.stop_file", arguments: [:])
        let stopPayload = try self.decodeToolPayload(stopResult)
        let fileSpans = stopPayload.objectValue?["spans"]?.arrayValue ?? []
        #expect(fileSpans.count == 1)
        #expect(fileSpans.first?.objectValue?["name"]?.stringValue == "after-start")
        #expect(fileSpans.first?.objectValue?["attributes"]?.objectValue?["phase"]?.stringValue == "file")
        #expect(FileManager.default.fileExists(atPath: filePath) == false)

        let stopAgainResult = await fixture.runtime.callTool(name: "trace.stop_file", arguments: [:])
        #expect(stopAgainResult.isError == true)
        let stopAgainPayload = try self.decodeToolPayload(stopAgainResult)
        #expect(stopAgainPayload.objectValue?["code"]?.stringValue == "trace_file_session_inactive")

        let restartResult = await fixture.runtime.callTool(name: "trace.start_file", arguments: [:])
        let restartPayload = try self.decodeToolPayload(restartResult)
        let discardPath = try #require(restartPayload.objectValue?["fileSession"]?.objectValue?["path"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: discardPath))

        let discardResult = await fixture.runtime.callTool(name: "trace.discard_file", arguments: [:])
        _ = try self.decodeToolPayload(discardResult)
        #expect(FileManager.default.fileExists(atPath: discardPath) == false)
    }

    @Test("Runtime exposes AdaUI inspection and safe actions")
    func runtimeInspectsAdaUIAndPerformsActions() async throws {
        let fixture = self.makeUIFixture()

        let listWindowsResult = await fixture.runtime.callTool(name: "ui.list_windows", arguments: [:])
        let listWindowsPayload = try self.decodeToolPayload(listWindowsResult)
        let windows = listWindowsPayload.objectValue?["windows"]?.arrayValue ?? []
        #expect(windows.count == 1)
        #expect(windows.first?.objectValue?["windowId"]?.intValue == fixture.window.id.id)

        let treeResult = await fixture.runtime.callTool(
            name: "ui.get_tree",
            arguments: ["windowId": .int(fixture.window.id.id)]
        )
        let treePayload = try self.decodeToolPayload(treeResult)
        let roots = treePayload.objectValue?["roots"]?.arrayValue ?? []
        #expect(roots.isEmpty == false)

        let foundNodeResult = await fixture.runtime.callTool(
            name: "ui.find_nodes",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("button.first")
            ]
        )
        let foundNodePayload = try self.decodeToolPayload(foundNodeResult)
        let foundNodes = foundNodePayload.objectValue?["nodes"]?.arrayValue ?? []
        #expect(foundNodes.count == 1)
        #expect(foundNodes.first?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.first")
        let primaryAbsoluteFrame = try #require(foundNodes.first?.objectValue?["absoluteFrame"]?.objectValue)
        let primaryOrigin = try #require(primaryAbsoluteFrame["origin"]?.objectValue)
        let primarySize = try #require(primaryAbsoluteFrame["size"]?.objectValue)
        let hitX = self.numericDouble(primaryOrigin["x"]) + self.numericDouble(primarySize["width"]) * 0.5
        let hitY = self.numericDouble(primaryOrigin["y"]) + self.numericDouble(primarySize["height"]) * 0.5

        let scrollNodeResult = await fixture.runtime.callTool(
            name: "ui.find_nodes",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "nodeType": .string("ScrollView")
            ]
        )
        let scrollNodePayload = try self.decodeToolPayload(scrollNodeResult)
        let scrollNodes = scrollNodePayload.objectValue?["nodes"]?.arrayValue ?? []
        #expect(scrollNodes.count == 1)
        #expect(scrollNodes.first?.objectValue?["nodeType"]?.stringValue?.contains("ScrollView") == true)

        let buttonViewResult = await fixture.runtime.callTool(
            name: "ui.find_nodes",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "viewType": .string("Button")
            ]
        )
        let buttonViewPayload = try self.decodeToolPayload(buttonViewResult)
        let buttonNodes = buttonViewPayload.objectValue?["nodes"]?.arrayValue ?? []
        #expect(buttonNodes.count >= 2)
        #expect(
            buttonNodes.contains {
                $0.objectValue?["accessibilityIdentifier"]?.stringValue == "button.first"
            }
        )

        let screenshotResult = await fixture.runtime.callTool(
            name: "ui.capture_node_screenshot",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("button.first")
            ]
        )
        let screenshotPayload = try self.decodeToolPayload(screenshotResult)
        let croppedPath = try #require(screenshotPayload.objectValue?["path"]?.stringValue)
        let croppedImage = try Image(contentsOf: URL(fileURLWithPath: croppedPath))
        let primaryMinX = self.numericDouble(primaryOrigin["x"])
        let primaryMinY = self.numericDouble(primaryOrigin["y"])
        let primaryMaxX = primaryMinX + self.numericDouble(primarySize["width"])
        let primaryMaxY = primaryMinY + self.numericDouble(primarySize["height"])
        let expectedCropWidth = max(
            0,
            min(240, Int(ceil(primaryMaxX))) - max(0, Int(floor(primaryMinX)))
        )
        let expectedCropHeight = max(
            0,
            min(180, Int(ceil(primaryMaxY))) - max(0, Int(floor(primaryMinY)))
        )
        #expect(screenshotPayload.objectValue?["width"]?.intValue == expectedCropWidth)
        #expect(screenshotPayload.objectValue?["height"]?.intValue == expectedCropHeight)
        #expect(croppedImage.width == expectedCropWidth)
        #expect(croppedImage.height == expectedCropHeight)
        let sourcePath = try #require(screenshotPayload.objectValue?["source"]?.objectValue?["path"]?.stringValue)
        #expect(URL(fileURLWithPath: sourcePath).lastPathComponent == "adamcp-ui-test.png")

        let hitTestResult = await fixture.runtime.callTool(
            name: "ui.hit_test",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "x": .double(hitX),
                "y": .double(hitY)
            ]
        )
        let hitTestPayload = try self.decodeToolPayload(hitTestResult)
        let hitPath = hitTestPayload.objectValue?["path"]?.arrayValue ?? []
        #expect(
            hitPath.contains {
                $0.objectValue?["accessibilityIdentifier"]?.stringValue == "button.first"
            }
        )

        let focusNodeResult = await fixture.runtime.callTool(
            name: "ui.focus_node",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("button.first")
            ]
        )
        let focusNodePayload = try self.decodeToolPayload(focusNodeResult)
        #expect(focusNodePayload.objectValue?["focusedNode"]?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.first")

        let focusNextResult = await fixture.runtime.callTool(
            name: "ui.focus_next",
            arguments: ["windowId": .int(fixture.window.id.id)]
        )
        let focusNextPayload = try self.decodeToolPayload(focusNextResult)
        #expect(focusNextPayload.objectValue?["focusedNode"]?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.second")

        let focusPreviousResult = await fixture.runtime.callTool(
            name: "ui.focus_previous",
            arguments: ["windowId": .int(fixture.window.id.id)]
        )
        let focusPreviousPayload = try self.decodeToolPayload(focusPreviousResult)
        #expect(focusPreviousPayload.objectValue?["focusedNode"]?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.first")

        let diagnosticsResult = await fixture.runtime.callTool(
            name: "ui.get_layout_diagnostics",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("button.tap"),
                "subtreeDepth": .int(1)
            ]
        )
        let diagnosticsPayload = try self.decodeToolPayload(diagnosticsResult)
        #expect(diagnosticsPayload.objectValue?["hasScrollContainer"]?.boolValue == true)
        #expect(diagnosticsPayload.objectValue?["target"]?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.tap")

        let overlayResult = await fixture.runtime.callTool(
            name: "ui.set_debug_overlay",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "mode": .string("layout_bounds")
            ]
        )
        let overlayPayload = try self.decodeToolPayload(overlayResult)
        #expect(overlayPayload.objectValue?["overlayMode"]?.stringValue == "layout_bounds")

        let scrollResult = await fixture.runtime.callTool(
            name: "ui.scroll_to_node",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("button.tap")
            ]
        )
        let scrollPayload = try self.decodeToolPayload(scrollResult)
        #expect(scrollPayload.objectValue?["target"]?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.tap")

        let tapResult = await fixture.runtime.callTool(
            name: "ui.tap_node",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("button.tap")
            ]
        )
        let tapPayload = try self.decodeToolPayload(tapResult)
        #expect(tapPayload.objectValue?["target"]?.objectValue?["accessibilityIdentifier"]?.stringValue == "button.tap")
        #expect(fixture.recorder.tapCount == 1)

        let ambiguousResult = await fixture.runtime.callTool(
            name: "ui.tap_node",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("duplicate.node")
            ]
        )
        #expect(ambiguousResult.isError == true)
        let ambiguousPayload = try self.decodeToolPayload(ambiguousResult)
        #expect(ambiguousPayload.objectValue?["code"]?.stringValue == "ui_node_ambiguous")

        let ambiguousScreenshotResult = await fixture.runtime.callTool(
            name: "ui.capture_node_screenshot",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "viewType": .string("Button")
            ]
        )
        #expect(ambiguousScreenshotResult.isError == true)
        let ambiguousScreenshotPayload = try self.decodeToolPayload(ambiguousScreenshotResult)
        #expect(ambiguousScreenshotPayload.objectValue?["code"]?.stringValue == "ui_node_ambiguous")

        let missingResult = await fixture.runtime.callTool(
            name: "ui.tap_node",
            arguments: [
                "windowId": .int(fixture.window.id.id),
                "accessibilityIdentifier": .string("missing.node")
            ]
        )
        #expect(missingResult.isError == true)
        let missingPayload = try self.decodeToolPayload(missingResult)
        #expect(missingPayload.objectValue?["code"]?.stringValue == "ui_node_not_found")

        let missingSelectorResult = await fixture.runtime.callTool(
            name: "ui.find_nodes",
            arguments: ["windowId": .int(fixture.window.id.id)]
        )
        #expect(missingSelectorResult.isError == true)
        let missingSelectorPayload = try self.decodeToolPayload(missingSelectorResult)
        #expect(missingSelectorPayload.objectValue?["code"]?.stringValue == "invalid_arguments")
    }

    private func makeFixture(traceRecorder: AdaMCPTraceRecorder? = nil) -> (runtime: AdaMCPRuntime, player: Entity) {
        Transform.registerComponent()
        InspectableSettings.registerResource()
        HiddenResource.registerResource()

        let world = World(name: "MainWorld")
        let player = world.spawn("Player") {
            Transform(position: [1, 2, 3])
            HiddenComponent(token: 7)
        }
        world.insertResource(InspectableSettings(label: "debug"))
        world.insertResource(HiddenResource(token: 99))

        let appWorlds = AppWorlds(main: world)
        let registry = MCPIntrospectionRegistry()
        registry.registerCodable(Transform.self, kind: .component)
        registry.registerCodable(
            InspectableSettings.self,
            kind: .resource,
            fields: [.init(name: "label", typeName: "String")]
        )

        let captureService = RenderCaptureService(
            appWorlds: appWorlds,
            captureOverride: { _, cameraEntityID, cameraName, _, _ in
                ScreenshotCaptureResult(
                    world: AppWorldName.main.rawValue,
                    cameraEntityID: cameraEntityID ?? 0,
                    cameraName: cameraName ?? "Primary",
                    width: 128,
                    height: 72,
                    path: "/tmp/adamcp-test.png",
                    timestamp: "2026-03-30T00:00:00Z"
                )
            }
        )

        let runtime = AdaMCPRuntime(
            appWorlds: appWorlds,
            registry: registry,
            renderCaptureService: captureService,
            traceRecorder: traceRecorder
        )
        return (runtime, player)
    }

    private func makeUIFixture() -> (runtime: AdaMCPRuntime, window: UIWindow, recorder: UITapRecorder) {
        let manager = TestWindowManager()
        UIWindowManager.setShared(manager)
        let world = World(name: "MainWorld")
        let appWorlds = AppWorlds(main: world)
        world.insertResource(WindowManagerResource(windowManager: manager))

        let registry = MCPIntrospectionRegistry()
        let captureService = RenderCaptureService(
            appWorlds: appWorlds,
            captureOverride: { _, _, _, _, _ in
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("adamcp-ui-test.png")
                try Image(width: 240, height: 180, color: .white).writePNG(to: outputURL)
                return ScreenshotCaptureResult(
                    world: AppWorldName.main.rawValue,
                    cameraEntityID: 0,
                    cameraName: "Primary",
                    width: 240,
                    height: 180,
                    path: outputURL.path,
                    timestamp: "2026-03-30T00:00:00Z"
                )
            }
        )

        let recorder = UITapRecorder()
        let window = UIWindow()
        window.frame = Rect(x: 0, y: 0, width: 240, height: 180)
        let container = UIContainerView(rootView: UITestRootView(recorder: recorder))
        container.frame = window.bounds
        window.addSubview(container)
        window.showWindow(makeFocused: true)
        window.layoutIfNeeded()

        let runtime = AdaMCPRuntime(
            appWorlds: appWorlds,
            registry: registry,
            renderCaptureService: captureService
        )

        return (runtime, window, recorder)
    }

    private func makeRenderGraphFixture() async throws -> (
        runtime: AdaMCPRuntime,
        appWorlds: AppWorlds,
        diagnostics: RenderGraphDiagnostics,
        camera: Entity
    ) {
        Camera.registerComponent()
        CameraRenderGraph.registerComponent()
        RenderViewTarget.registerComponent()

        let mainWorld = World(name: "MainWorld")
        mainWorld.insertResource(SimulationControl(
            mode: .paused,
            reason: "before collect",
            pendingStepCount: 5
        ))

        let renderWorld = World(name: "RenderWorld")
        var rootGraph = RenderGraph(label: "Root Graph")
        var subgraph = RenderGraph(label: "Sub Graph A")
        subgraph.addNode(AdaMCPTestNoopRenderNode(), by: "Sub Noop")
        rootGraph.addNode(RunGraphNode(graphName: "Sub Graph A"), by: "Run Sub")
        rootGraph.addSubgraph(subgraph, name: "Sub Graph A")

        let diagnostics = RenderGraphDiagnostics(isEnabled: false, capacity: 2)
        renderWorld.insertResource(rootGraph)
        renderWorld.insertResource(diagnostics)
        renderWorld.addSystem(AdaMCPTestRenderGraphSystem.self, on: .update)

        let camera = renderWorld.spawn("Primary Camera") {
            Camera()
            CameraRenderGraph(subgraphLabel: "Sub Graph A", inputSlot: "view")
            RenderViewTarget()
        }

        let appWorlds = AppWorlds(main: mainWorld)
        appWorlds.updateScheduler = .update

        let renderApp = AppWorlds(main: renderWorld)
        renderApp.updateScheduler = .update
        appWorlds.addSubworld(renderApp, by: .renderWorld)
        try await appWorlds.build()

        let runtime = AdaMCPRuntime(
            appWorlds: appWorlds,
            registry: MCPIntrospectionRegistry(),
            renderCaptureService: RenderCaptureService(appWorlds: appWorlds)
        )

        return (runtime, appWorlds, diagnostics, camera)
    }

    private func decodeToolPayload(_ result: CallTool.Result) throws -> Value {
        try self.decodeToolPayload(result.content)
    }

    private func numericDouble(_ value: Value?) -> Double {
        value?.doubleValue ?? value?.intValue.map(Double.init) ?? 0
    }

    private func decodeToolPayload(_ content: [Tool.Content]) throws -> Value {
        let text = try #require(self.firstToolText(in: content))
        let data = try #require(text.data(using: .utf8))
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func decodeResourcePayload(_ contents: [MCP.Resource.Content]) throws -> Value {
        let text = try #require(contents.first?.text)
        let data = try #require(text.data(using: .utf8))
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func firstToolText(in content: [Tool.Content]) -> String? {
        for item in content {
            if case .text(let text, _, _) = item {
                return text
            }
        }
        return nil
    }
}

private struct AdaMCPTestRenderGraphSystem: System {
    init(world: World) { }

    func update(context: UpdateContext) async {
        guard let graph = context.world.getResource(RenderGraph.self) else {
            return
        }

        do {
            try await RenderGraphExecutor().execute(
                graph,
                renderDevice: AdaMCPTestRenderDevice(),
                in: context.world,
                diagnostics: context.world.getResource(RenderGraphDiagnostics.self)
            )
        } catch {
            Issue.record("Render graph test system failed: \(error.localizedDescription)")
        }
    }
}

private struct AdaMCPTestNoopRenderNode: RenderNode {
    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        []
    }
}

private final class AdaMCPTestRenderDevice: RenderDevice, @unchecked Sendable {
    func createBuffer(label: String?, length: Int, options: ResourceOptions) -> Buffer {
        AdaMCPTestBuffer(label: label, length: length)
    }

    func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> Buffer {
        AdaMCPTestBuffer(label: label, length: length)
    }

    func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> IndexBuffer {
        AdaMCPTestIndexBuffer(label: label, length: length, indexFormat: format)
    }

    func createVertexBuffer(label: String?, length: Int, binding: Int) -> VertexBuffer {
        AdaMCPTestVertexBuffer(label: label, length: length, binding: binding)
    }

    func compileShader(from shader: Shader) throws -> any CompiledShader {
        fatalError("Not used by AdaMCP render graph tests.")
    }

    func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> RenderPipeline {
        fatalError("Not used by AdaMCP render graph tests.")
    }

    func createSampler(from descriptor: SamplerDescriptor) -> Sampler {
        AdaMCPTestSampler(descriptor: descriptor)
    }

    func createUniformBuffer(length: Int, binding: Int) -> UniformBuffer {
        AdaMCPTestUniformBuffer(label: nil, length: length, binding: binding)
    }

    func createTexture(from descriptor: TextureDescriptor) -> GPUTexture {
        AdaMCPTestGPUTexture(
            size: SizeInt(width: descriptor.width, height: descriptor.height),
            label: descriptor.debugLabel
        )
    }

    func getImage(from texture: Texture) -> Image? {
        nil
    }

    func createCommandQueue() -> CommandQueue {
        AdaMCPTestCommandQueue()
    }

    @MainActor
    func createSwapchain(from window: WindowID) -> (any Swapchain)? {
        nil
    }
}

private class AdaMCPTestBuffer: Buffer, @unchecked Sendable {
    var label: String?
    let length: Int
    private let pointer: UnsafeMutableRawPointer

    init(label: String?, length: Int) {
        self.label = label
        self.length = length
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 1)
    }

    deinit {
        pointer.deallocate()
    }

    func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int, offset: Int) {}
    func contents() -> UnsafeMutableRawPointer { pointer }
    func unmap() {}
}

private final class AdaMCPTestIndexBuffer: AdaMCPTestBuffer, IndexBuffer, @unchecked Sendable {
    let indexFormat: IndexBufferFormat

    init(label: String?, length: Int, indexFormat: IndexBufferFormat) {
        self.indexFormat = indexFormat
        super.init(label: label, length: length)
    }
}

private final class AdaMCPTestVertexBuffer: AdaMCPTestBuffer, VertexBuffer, @unchecked Sendable {
    let binding: Int

    init(label: String?, length: Int, binding: Int) {
        self.binding = binding
        super.init(label: label, length: length)
    }
}

private final class AdaMCPTestUniformBuffer: AdaMCPTestBuffer, UniformBuffer, @unchecked Sendable {
    let binding: Int

    init(label: String?, length: Int, binding: Int) {
        self.binding = binding
        super.init(label: label, length: length)
    }
}

private final class AdaMCPTestSampler: Sampler {
    let descriptor: SamplerDescriptor

    init(descriptor: SamplerDescriptor) {
        self.descriptor = descriptor
    }
}

private final class AdaMCPTestGPUTexture: GPUTexture {
    let size: SizeInt
    var label: String?

    init(size: SizeInt, label: String?) {
        self.size = size
        self.label = label
    }

    func replaceRegion(_ region: RectInt, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {}
}

private final class AdaMCPTestCommandQueue: CommandQueue {
    func makeCommandBuffer() -> CommandBuffer {
        AdaMCPTestCommandBuffer()
    }
}

private final class AdaMCPTestCommandBuffer: CommandBuffer {
    var label: String?

    func beginRenderPass(_ desc: RenderPassDescriptor) -> RenderCommandEncoder {
        fatalError("Not used by AdaMCP render graph tests.")
    }

    func beginBlitPass(_ desc: BlitPassDescriptor) -> BlitCommandEncoder {
        fatalError("Not used by AdaMCP render graph tests.")
    }

    func commit() {}
    func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {}
}
