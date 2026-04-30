import AdaEngine
import Foundation

public struct ScreenshotCaptureResult: Codable, Hashable, Sendable {
    public let world: String
    public let cameraEntityID: Int
    public let cameraName: String
    public let width: Int
    public let height: Int
    public let path: String
    public let timestamp: String

    public init(
        world: String,
        cameraEntityID: Int,
        cameraName: String,
        width: Int,
        height: Int,
        path: String,
        timestamp: String
    ) {
        self.world = world
        self.cameraEntityID = cameraEntityID
        self.cameraName = cameraName
        self.width = width
        self.height = height
        self.path = path
        self.timestamp = timestamp
    }
}

public struct ScreenshotCropRect: Codable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct UINodeScreenshotCaptureResult: Codable, Hashable, Sendable {
    public let windowId: Int
    public let node: UINodeSnapshot
    public let source: ScreenshotCaptureResult
    public let cropRect: ScreenshotCropRect
    public let width: Int
    public let height: Int
    public let path: String
    public let timestamp: String

    public init(
        windowId: Int,
        node: UINodeSnapshot,
        source: ScreenshotCaptureResult,
        cropRect: ScreenshotCropRect,
        width: Int,
        height: Int,
        path: String,
        timestamp: String
    ) {
        self.windowId = windowId
        self.node = node
        self.source = source
        self.cropRect = cropRect
        self.width = width
        self.height = height
        self.path = path
        self.timestamp = timestamp
    }
}

@MainActor
public final class RenderCaptureService: @unchecked Sendable, Resource {
    public typealias CaptureOverride = @MainActor (
        _ appWorlds: AppWorlds,
        _ cameraEntityID: Int?,
        _ cameraName: String?,
        _ pauseBeforeCapture: Bool,
        _ refreshFrame: Bool
    ) async throws -> ScreenshotCaptureResult

    private weak var appWorlds: AppWorlds?
    private let captureOverride: CaptureOverride?

    public init(
        appWorlds: AppWorlds,
        captureOverride: CaptureOverride? = nil
    ) {
        self.appWorlds = appWorlds
        self.captureOverride = captureOverride
    }

    public func capture(
        cameraEntityID: Int? = nil,
        cameraName: String? = nil,
        pauseBeforeCapture: Bool = true,
        refreshFrame: Bool = true
    ) async throws -> ScreenshotCaptureResult {
        guard let appWorlds else {
            throw AdaMCPError.screenshotUnavailable("Render capture service is detached from the app.")
        }

        if let captureOverride {
            return try await captureOverride(
                appWorlds,
                cameraEntityID,
                cameraName,
                pauseBeforeCapture,
                refreshFrame
            )
        }

        let simulationControl = appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }

        if pauseBeforeCapture && simulationControl.wrappedValue.mode == .running {
            simulationControl.wrappedValue.mode = .paused
            simulationControl.wrappedValue.reason = "render.capture_screenshot"
        }

        if refreshFrame {
            try await appWorlds.update()
        }

        guard let renderWorld = appWorlds.getSubworldBuilder(by: .renderWorld) else {
            throw AdaMCPError.screenshotUnavailable("Render world is unavailable.")
        }

        let cameraEntity = try self.resolveCamera(
            in: renderWorld.main,
            cameraEntityID: cameraEntityID,
            cameraName: cameraName
        )
        guard let renderViewTarget = cameraEntity.components[RenderViewTarget.self] else {
            throw AdaMCPError.screenshotUnavailable("Camera '\(cameraEntity.name)' has no render target.")
        }
        guard let texture = renderViewTarget.mainTexture ?? renderViewTarget.outputTexture else {
            throw AdaMCPError.screenshotUnavailable("Camera '\(cameraEntity.name)' has no readable texture.")
        }

        let image = texture.image
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("adamcp-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = "capture-\(cameraEntity.id)-\(UUID().uuidString).png"
        let outputURL = outputDirectory.appendingPathComponent(fileName)
        try image.writePNG(to: outputURL)

        return ScreenshotCaptureResult(
            world: AppWorldName.renderWorld.rawValue,
            cameraEntityID: cameraEntity.id,
            cameraName: cameraEntity.name,
            width: image.width,
            height: image.height,
            path: outputURL.path,
            timestamp: timestamp
        )
    }

    private func resolveCamera(
        in world: World,
        cameraEntityID: Int?,
        cameraName: String?
    ) throws -> Entity {
        if let cameraEntityID {
            guard let entity = world.getEntityByID(cameraEntityID),
                  entity.components.has(Camera.self) else {
                throw AdaMCPError.entityNotFound(world: AppWorldName.renderWorld.rawValue, entityID: cameraEntityID)
            }
            return entity
        }

        let cameras = world.getEntities()
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

        throw AdaMCPError.screenshotUnavailable("No camera available for screenshot capture.")
    }
}

extension Image {
    func adamcpCropped(to cropRect: ScreenshotCropRect) throws -> Image {
        guard cropRect.width > 0, cropRect.height > 0 else {
            throw AdaMCPError.screenshotUnavailable("Crop rectangle must have positive dimensions.")
        }
        guard cropRect.x >= 0,
              cropRect.y >= 0,
              cropRect.x + cropRect.width <= self.width,
              cropRect.y + cropRect.height <= self.height else {
            throw AdaMCPError.screenshotUnavailable("Crop rectangle is outside the source screenshot.")
        }

        let sourceStride = self.adamcpPixelStride
        let rowByteCount = cropRect.width * sourceStride
        var croppedData = Data(capacity: rowByteCount * cropRect.height)

        for row in 0..<cropRect.height {
            let sourceOffset = ((cropRect.y + row) * self.width + cropRect.x) * sourceStride
            let sourceRange = sourceOffset..<(sourceOffset + rowByteCount)
            croppedData.append(self.data.subdata(in: sourceRange))
        }

        return Image(
            width: cropRect.width,
            height: cropRect.height,
            data: croppedData,
            format: self.format
        )
    }

    private var adamcpPixelStride: Int {
        switch self.format {
        case .rgba8, .bgra8, .bgra8_sRGB:
            return 4
        case .rgb8:
            return 3
        case .gray:
            return 1
        }
    }
}

public final class MCPServerRuntime: @unchecked Sendable, Resource {
    public private(set) var endpointURL: URL?
    public private(set) var isRunning = false
    public private(set) var httpEndpointURL: URL?
    public private(set) var httpIsRunning = false
    public private(set) var stdioIsRunning = false

    public init() {}

    public func update(endpointURL: URL?, isRunning: Bool) {
        self.updateHTTP(endpointURL: endpointURL, isRunning: isRunning)
    }

    public func updateHTTP(endpointURL: URL?, isRunning: Bool) {
        self.endpointURL = endpointURL
        self.httpEndpointURL = endpointURL
        self.httpIsRunning = isRunning
        self.isRunning = self.httpIsRunning || self.stdioIsRunning
    }

    public func updateStdio(isRunning: Bool) {
        self.stdioIsRunning = isRunning
        self.isRunning = self.httpIsRunning || self.stdioIsRunning
    }
}
