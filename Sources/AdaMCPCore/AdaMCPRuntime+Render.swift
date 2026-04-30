import MCP

extension AdaMCPRuntime {
    func captureScreenshotPayload(arguments: [String: Value]) async throws -> Value {
        let result = try await renderCaptureService.capture(
            cameraEntityID: arguments["cameraEntityId"]?.intValue,
            cameraName: arguments["cameraName"]?.stringValue,
            pauseBeforeCapture: arguments["pauseBeforeCapture"]?.boolValue ?? true,
            refreshFrame: true
        )
        return try Value(result)
    }
}
