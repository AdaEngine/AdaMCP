import AdaEngine
import Foundation
import MCP

public struct RenderGraphAttachmentDumpResult: Codable, Hashable, Sendable {
    public let world: String
    public let cameraEntityID: Int?
    public let cameraName: String?
    public let attachment: RenderTargetAttachmentSummary
    public let isDumped: Bool
    public let width: Int?
    public let height: Int?
    public let path: String?
    public let timestamp: String
    public let unsupportedReason: String?
}

extension AdaMCPRuntime {
    func renderGraphGetPayload(arguments: [String: Value]) throws -> Value {
        let includeSubgraphs = arguments["includeSubgraphs"]?.boolValue ?? true
        let snapshot = try self.currentRenderGraphSnapshot(includeSubgraphs: includeSubgraphs)
        return try Value([
            "backend": try self.renderBackendPayload(),
            "graph": try Value(snapshot),
            "cameras": try Value(self.renderCameraSnapshots())
        ] as [String: Value])
    }

    func renderGraphCollectFramesPayload(arguments: [String: Value]) async throws -> Value {
        let frameCount = max(arguments["frames"]?.intValue ?? 3, 1)
        let pauseBeforeCapture = arguments["pauseBeforeCapture"]?.boolValue ?? true
        let clearBeforeCollect = arguments["clearBeforeCollect"]?.boolValue ?? true
        let renderWorld = try self.renderWorld()
        let diagnostics = renderWorld.getOrInitRefResource(RenderGraphDiagnostics.self) {
            RenderGraphDiagnostics()
        }.wrappedValue

        let previousEnabled = diagnostics.isEnabled
        let previousCapacity = diagnostics.capacity
        let requestedCapacity = max(previousCapacity, frameCount * 8)
        diagnostics.configure(isEnabled: true, capacity: requestedCapacity)
        defer {
            diagnostics.configure(isEnabled: previousEnabled, capacity: previousCapacity)
        }

        if clearBeforeCollect {
            diagnostics.clear()
        }

        let control = appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        let previousMode = control.wrappedValue.mode
        let previousReason = control.wrappedValue.reason
        let previousPendingStepCount = control.wrappedValue.pendingStepCount
        defer {
            control.wrappedValue.mode = previousMode
            control.wrappedValue.reason = previousReason
            control.wrappedValue.pendingStepCount = previousPendingStepCount
        }

        if pauseBeforeCapture {
            control.wrappedValue.mode = .paused
            control.wrappedValue.reason = "render_graph.collect_frames"
            control.wrappedValue.pendingStepCount += frameCount
        }

        for _ in 0..<frameCount {
            try await appWorlds.update()
        }

        let records = diagnostics.recentFrames(limit: requestedCapacity)

        return try Value([
            "requestedFrames": .int(frameCount),
            "records": try Value(records),
            "backend": try self.renderBackendPayload()
        ] as [String: Value])
    }

    func renderGraphDumpAttachmentPayload(arguments: [String: Value]) async throws -> Value {
        let attachmentName = arguments["attachment"]?.stringValue ?? "main"
        let pauseBeforeCapture = arguments["pauseBeforeCapture"]?.boolValue ?? true
        let refreshFrame = arguments["refreshFrame"]?.boolValue ?? true

        let control = appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        if pauseBeforeCapture && control.wrappedValue.mode == .running {
            control.wrappedValue.mode = .paused
            control.wrappedValue.reason = "render_graph.dump_attachment"
        }

        if refreshFrame {
            try await appWorlds.update()
        }

        let cameraEntity = try self.resolveRenderCamera(
            cameraEntityID: arguments["cameraEntityId"]?.intValue,
            cameraName: arguments["cameraName"]?.stringValue
        )
        guard let renderViewTarget = cameraEntity.components[RenderViewTarget.self] else {
            throw AdaMCPError.screenshotUnavailable("Camera '\(cameraEntity.name)' has no render target.")
        }

        let texture = try self.renderAttachment(named: attachmentName, from: renderViewTarget)
        let summary = RenderTargetAttachmentSummary(name: attachmentName, texture: texture)
        let timestamp = ISO8601DateFormatter().string(from: Date())

        guard let texture else {
            return try Value(RenderGraphAttachmentDumpResult(
                world: AppWorldName.renderWorld.rawValue,
                cameraEntityID: cameraEntity.id,
                cameraName: cameraEntity.name,
                attachment: summary,
                isDumped: false,
                width: nil,
                height: nil,
                path: nil,
                timestamp: timestamp,
                unsupportedReason: summary.unsupportedReason
            ))
        }

        guard summary.isReadableColor else {
            return try Value(RenderGraphAttachmentDumpResult(
                world: AppWorldName.renderWorld.rawValue,
                cameraEntityID: cameraEntity.id,
                cameraName: cameraEntity.name,
                attachment: summary,
                isDumped: false,
                width: texture.width,
                height: texture.height,
                path: nil,
                timestamp: timestamp,
                unsupportedReason: summary.unsupportedReason
            ))
        }

        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("adamcp-render-attachments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let fileName = "attachment-\(cameraEntity.id)-\(attachmentName)-\(UUID().uuidString).png"
        let outputURL = outputDirectory.appendingPathComponent(fileName)
        let image = texture.image
        try image.writePNG(to: outputURL)

        return try Value(RenderGraphAttachmentDumpResult(
            world: AppWorldName.renderWorld.rawValue,
            cameraEntityID: cameraEntity.id,
            cameraName: cameraEntity.name,
            attachment: summary,
            isDumped: true,
            width: image.width,
            height: image.height,
            path: outputURL.path,
            timestamp: timestamp,
            unsupportedReason: nil
        ))
    }

    func renderResourcePayload(url: URL, uri: String) throws -> Value {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else {
            throw AdaMCPError.invalidResourceURI(uri)
        }

        switch first {
        case "graphs":
            return try self.renderGraphGetPayload(arguments: [:])
        case "graph":
            guard parts.count == 2 else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            let label = parts[1].removingPercentEncoding ?? parts[1]
            let snapshot = try self.currentRenderGraphSnapshot(includeSubgraphs: true)
            guard let selected = snapshot.firstGraphSnapshot(label: label) else {
                throw AdaMCPError.resourceNotFound(label)
            }
            return try Value(selected)
        case "frames":
            guard parts.dropFirst().first == "recent" else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            let diagnostics = try self.renderWorld().getResource(RenderGraphDiagnostics.self)
            return try Value(diagnostics?.recentFrames() ?? [])
        case "cameras":
            return try Value(self.renderCameraSnapshots())
        default:
            throw AdaMCPError.invalidResourceURI(uri)
        }
    }
}

private extension AdaMCPRuntime {
    func renderWorld() throws -> World {
        guard let renderWorld = appWorlds.getSubworldBuilder(by: .renderWorld) else {
            throw AdaMCPError.screenshotUnavailable("Render world is unavailable.")
        }
        return renderWorld.main
    }

    func currentRenderGraphSnapshot(includeSubgraphs: Bool) throws -> RenderGraphSnapshot {
        guard let renderGraph = try self.renderWorld().getResource(RenderGraph.self) else {
            throw AdaMCPError.resourceNotFound(String(reflecting: RenderGraph.self))
        }
        return renderGraph.makeSnapshot(includeSubgraphs: includeSubgraphs)
    }

    func renderBackendPayload() throws -> Value {
        let renderWorld = try self.renderWorld()
        let backend = renderWorld.getResource(RenderEngineHandler.self)?.renderEngine.type.rawValue ?? "unknown"
        return [
            "type": .string(backend),
            "maxFramesInFlight": .int(unsafe RenderEngine.configurations.maxFramesInFlight),
            "capabilities": [
                "programmaticCapture": .object([
                    "supported": .bool(backend == RenderBackendType.metal.rawValue),
                    "provider": .string(backend == RenderBackendType.metal.rawValue ? "MTLCaptureManager" : "none")
                ]),
                "gpuCounters": .object([
                    "supported": .bool(backend == RenderBackendType.metal.rawValue),
                    "provider": .string(backend == RenderBackendType.metal.rawValue ? "MTLCounterSampleBuffer" : "none")
                ]),
                "timestampQueries": .object([
                    "supported": .bool(false),
                    "provider": .string(backend == RenderBackendType.webgpu.rawValue ? "WebGPU GPUQuerySet, runtime dependent" : "none")
                ])
            ]
        ]
    }

    func renderCameraSnapshots() throws -> [Value] {
        let renderWorld = try self.renderWorld()
        return try renderWorld.getEntities()
            .filter { $0.components.has(Camera.self) }
            .sorted { lhs, rhs in
                let lhsOrder = lhs.components[Camera.self]?.renderOrder ?? 0
                let rhsOrder = rhs.components[Camera.self]?.renderOrder ?? 0
                return lhsOrder < rhsOrder
            }
            .map { entity in
                let camera = entity.components[Camera.self]
                let renderGraph = entity.components[CameraRenderGraph.self]
                let target = entity.components[RenderViewTarget.self]
                let attachments: [Value] = try [
                    Value(RenderTargetAttachmentSummary(name: "main", texture: target?.mainTexture)),
                    Value(RenderTargetAttachmentSummary(name: "output", texture: target?.outputTexture)),
                    Value(RenderTargetAttachmentSummary(name: "depth", texture: target?.depthTexture)),
                    Value(RenderTargetAttachmentSummary(name: "sceneColor", texture: target?.sceneColorTexture)),
                    Value(RenderTargetAttachmentSummary(name: "lightAccum", texture: target?.lightAccumTexture)),
                    Value(RenderTargetAttachmentSummary(name: "shadowMask", texture: target?.shadowMaskTexture))
                ]
                return [
                    "entityId": .int(entity.id),
                    "name": .string(entity.name),
                    "isActive": .bool(camera?.isActive ?? false),
                    "renderOrder": .int(camera?.renderOrder ?? 0),
                    "graph": .object([
                        "subgraphLabel": .string(renderGraph?.subgraphLabel.rawValue ?? ""),
                        "inputSlot": .string(renderGraph?.inputSlot.rawValue ?? "")
                    ]),
                    "attachments": .array(attachments)
                ]
            }
    }

    func resolveRenderCamera(cameraEntityID: Int?, cameraName: String?) throws -> Entity {
        let renderWorld = try self.renderWorld()
        if let cameraEntityID {
            guard let entity = renderWorld.getEntityByID(cameraEntityID),
                  entity.components.has(Camera.self) else {
                throw AdaMCPError.entityNotFound(world: AppWorldName.renderWorld.rawValue, entityID: cameraEntityID)
            }
            return entity
        }

        let cameras = renderWorld.getEntities()
            .filter { $0.components.has(Camera.self) }
            .sorted { lhs, rhs in
                let lhsOrder = lhs.components[Camera.self]?.renderOrder ?? 0
                let rhsOrder = rhs.components[Camera.self]?.renderOrder ?? 0
                return lhsOrder < rhsOrder
            }

        if let cameraName {
            if let entity = cameras.first(where: { $0.name == cameraName }) {
                return entity
            }
            throw AdaMCPError.screenshotUnavailable("Camera named '\(cameraName)' was not found.")
        }

        if let entity = cameras.first(where: { $0.components[Camera.self]?.isActive == true }) ?? cameras.first {
            return entity
        }

        throw AdaMCPError.screenshotUnavailable("No camera available for render graph attachment dump.")
    }

    func renderAttachment(named name: String, from target: RenderViewTarget) throws -> RenderTexture? {
        switch name {
        case "main":
            return target.mainTexture
        case "output":
            return target.outputTexture
        case "depth":
            return target.depthTexture
        case "sceneColor":
            return target.sceneColorTexture
        case "lightAccum":
            return target.lightAccumTexture
        case "shadowMask":
            return target.shadowMaskTexture
        default:
            throw AdaMCPError.invalidArguments("Unsupported render graph attachment '\(name)'.")
        }
    }
}

private extension RenderGraphSnapshot {
    func firstGraphSnapshot(label: String) -> RenderGraphSnapshot? {
        if self.label == label {
            return self
        }
        for subgraph in subgraphs {
            if let match = subgraph.firstGraphSnapshot(label: label) {
                return match
            }
        }
        return nil
    }
}
