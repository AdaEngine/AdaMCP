import AdaEngine
import Foundation
import MCP

private enum UIQuerySelector {
    case node(UINodeSelector)
    case nodeType(String)
    case viewType(String)

    var externalValue: String {
        switch self {
        case .node(let selector):
            return selector.externalValue
        case .nodeType(let value):
            return "nodeType:\(value)"
        case .viewType(let value):
            return "viewType:\(value)"
        }
    }

    var engineSelector: UINodeSelector? {
        switch self {
        case .node(let selector):
            return selector
        case .nodeType, .viewType:
            return nil
        }
    }
}

extension AdaMCPRuntime {
    func uiListWindowsPayload() throws -> Value {
        ["windows": try Value(self.uiInspectionService.listWindows())]
    }

    func uiGetWindowPayload(arguments: [String: Value]) throws -> Value {
        try Value(self.uiInspectionService.getWindow(windowID: arguments["windowId"]?.intValue))
    }

    func uiGetTreePayload(arguments: [String: Value]) throws -> Value {
        try Value(self.uiInspectionService.getTree(windowID: arguments["windowId"]?.intValue))
    }

    func uiGetNodePayload(arguments: [String: Value]) throws -> Value {
        try Value(
            self.uiInspectionService.getNode(
                windowID: arguments["windowId"]?.intValue,
                selector: try self.resolveUINodeSelector(arguments: arguments)
            )
        )
    }

    func uiFindNodesPayload(arguments: [String: Value]) throws -> Value {
        guard let selector = self.resolveOptionalUIQuerySelector(arguments: arguments) else {
            throw AdaMCPError.invalidArguments("Argument 'accessibilityIdentifier', 'runtimeId', 'nodeType', or 'viewType' is required.")
        }
        let nodes = try self.findUINodes(
            windowID: arguments["windowId"]?.intValue,
            selector: selector
        )
        return ["nodes": try Value(nodes)]
    }

    func uiCaptureNodeScreenshotPayload(arguments: [String: Value]) async throws -> Value {
        let selector = try self.resolveUIQuerySelector(arguments: arguments)
        let window = try self.uiInspectionService.getWindow(windowID: arguments["windowId"]?.intValue)
        let node = try self.resolveUniqueUINode(window: window, selector: selector)
        let source = try await renderCaptureService.capture(
            cameraEntityID: arguments["cameraEntityId"]?.intValue,
            cameraName: arguments["cameraName"]?.stringValue,
            pauseBeforeCapture: arguments["pauseBeforeCapture"]?.boolValue ?? true,
            refreshFrame: true
        )

        let sourceImage = try Image(contentsOf: URL(fileURLWithPath: source.path))
        let cropRect = try self.nodeCropRect(
            node: node,
            window: window,
            sourceImage: sourceImage,
            padding: max(0, Float(self.doubleArgument(arguments, "padding") ?? 0)),
            selector: selector
        )
        let croppedImage = try sourceImage.adamcpCropped(to: cropRect)
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("adamcp-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let outputURL = outputDirectory
            .appendingPathComponent("node-capture-\(window.summary.windowId)-\(UUID().uuidString).png")
        try croppedImage.writePNG(to: outputURL)

        return try Value(UINodeScreenshotCaptureResult(
            windowId: window.summary.windowId,
            node: node,
            source: source,
            cropRect: cropRect,
            width: croppedImage.width,
            height: croppedImage.height,
            path: outputURL.path,
            timestamp: timestamp
        ))
    }

    func uiHitTestPayload(arguments: [String: Value]) throws -> Value {
        let x = arguments["x"]?.doubleValue ?? arguments["x"]?.intValue.map(Double.init)
        let y = arguments["y"]?.doubleValue ?? arguments["y"]?.intValue.map(Double.init)
        guard let x, let y else {
            throw AdaMCPError.invalidArguments("Arguments 'x' and 'y' are required.")
        }

        return try Value(
            self.uiInspectionService.hitTest(
                windowID: arguments["windowId"]?.intValue,
                point: Point(Float(x), Float(y))
            )
        )
    }

    func uiLayoutDiagnosticsPayload(arguments: [String: Value]) throws -> Value {
        try Value(
            self.uiInspectionService.getLayoutDiagnostics(
                windowID: arguments["windowId"]?.intValue,
                selector: self.resolveOptionalUINodeSelector(arguments: arguments),
                subtreeDepth: arguments["subtreeDepth"]?.intValue
            )
        )
    }

    func uiSetDebugOverlayPayload(arguments: [String: Value]) throws -> Value {
        guard let rawMode = arguments["mode"]?.stringValue,
              let mode = UIDebugOverlayMode(rawValue: rawMode) else {
            throw AdaMCPError.invalidArguments("Argument 'mode' must be one of off, layout_bounds, focused_node, hit_test_target.")
        }
        return try Value(
            self.uiInspectionService.setDebugOverlay(
                windowID: arguments["windowId"]?.intValue,
                mode: mode
            )
        )
    }

    func uiFocusNodePayload(arguments: [String: Value]) throws -> Value {
        try Value(
            self.uiInspectionService.focusNode(
                windowID: arguments["windowId"]?.intValue,
                selector: try self.resolveUINodeSelector(arguments: arguments)
            )
        )
    }

    func uiFocusNextPayload(arguments: [String: Value]) throws -> Value {
        try Value(self.uiInspectionService.focusNext(windowID: arguments["windowId"]?.intValue))
    }

    func uiFocusPreviousPayload(arguments: [String: Value]) throws -> Value {
        try Value(self.uiInspectionService.focusPrevious(windowID: arguments["windowId"]?.intValue))
    }

    func uiScrollToNodePayload(arguments: [String: Value]) throws -> Value {
        try Value(
            self.uiInspectionService.scrollToNode(
                windowID: arguments["windowId"]?.intValue,
                selector: try self.resolveUINodeSelector(arguments: arguments)
            )
        )
    }

    func uiTapNodePayload(arguments: [String: Value]) throws -> Value {
        try Value(
            self.uiInspectionService.tapNode(
                windowID: arguments["windowId"]?.intValue,
                selector: try self.resolveUINodeSelector(arguments: arguments)
            )
        )
    }

    func uiResourcePayload(url: URL, uri: String) throws -> Value {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let kind = parts.first else {
            throw AdaMCPError.invalidResourceURI(uri)
        }

        switch kind {
        case "windows":
            return try self.uiListWindowsPayload()
        case "window":
            guard parts.count == 2, let windowID = Int(parts[1]) else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            return try Value(self.uiInspectionService.getWindow(windowID: windowID))
        case "tree":
            guard parts.count == 2, let windowID = Int(parts[1]) else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            return try Value(self.uiInspectionService.getTree(windowID: windowID))
        case "node":
            guard parts.count >= 3, let windowID = Int(parts[1]) else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            let nodeRef = parts.dropFirst(2).joined(separator: "/")
            return try Value(
                self.uiInspectionService.getNode(
                    windowID: windowID,
                    selector: try self.parseUINodeRef(nodeRef)
                )
            )
        default:
            throw AdaMCPError.invalidResourceURI(uri)
        }
    }
}

private extension AdaMCPRuntime {
    func findUINodes(windowID: Int?, selector: UIQuerySelector) throws -> [UINodeSnapshot] {
        if let engineSelector = selector.engineSelector {
            return try self.uiInspectionService.findNodes(windowID: windowID, selector: engineSelector)
        }

        let tree = try self.uiInspectionService.getTree(windowID: windowID)
        return tree.roots.flatMap { self.collectUINodes(in: $0, matching: selector) }
    }

    func resolveUniqueUINode(window: UIWindowSnapshot, selector: UIQuerySelector) throws -> UINodeSnapshot {
        if let engineSelector = selector.engineSelector {
            return try self.uiInspectionService.getNode(
                windowID: window.summary.windowId,
                selector: engineSelector
            )
        }

        let matches = window.roots.flatMap { self.collectUINodes(in: $0, matching: selector) }
        guard let first = matches.first else {
            throw AdaMCPError.uiNodeNotFound(selector.externalValue)
        }
        guard matches.count == 1 else {
            throw AdaMCPError.uiNodeAmbiguous(
                selector: selector.externalValue,
                candidates: matches.map(self.uiNodeSummary)
            )
        }
        return first
    }

    func collectUINodes(in node: UINodeSnapshot, matching selector: UIQuerySelector) -> [UINodeSnapshot] {
        var matches: [UINodeSnapshot] = []
        if self.uiNode(node, matches: selector) {
            matches.append(self.limitedUINodeSnapshot(node, maxDepth: 1))
        }

        for child in node.children {
            matches.append(contentsOf: self.collectUINodes(in: child, matching: selector))
        }
        return matches
    }

    func uiNode(_ node: UINodeSnapshot, matches selector: UIQuerySelector) -> Bool {
        switch selector {
        case .node:
            return false
        case .nodeType(let query):
            return node.nodeType.localizedCaseInsensitiveContains(query)
        case .viewType(let query):
            return node.viewType.localizedCaseInsensitiveContains(query)
        }
    }

    func limitedUINodeSnapshot(_ node: UINodeSnapshot, maxDepth: Int) -> UINodeSnapshot {
        UINodeSnapshot(
            runtimeId: node.runtimeId,
            accessibilityIdentifier: node.accessibilityIdentifier,
            nodeType: node.nodeType,
            viewType: node.viewType,
            frame: node.frame,
            absoluteFrame: node.absoluteFrame,
            canBecomeFocused: node.canBecomeFocused,
            isFocused: node.isFocused,
            isHidden: node.isHidden,
            isInteractable: node.isInteractable,
            parent: node.parent,
            children: maxDepth > 0
                ? node.children.map { self.limitedUINodeSnapshot($0, maxDepth: maxDepth - 1) }
                : []
        )
    }

    func uiNodeSummary(_ node: UINodeSnapshot) -> UINodeSummary {
        UINodeSummary(
            runtimeId: node.runtimeId,
            accessibilityIdentifier: node.accessibilityIdentifier,
            nodeType: node.nodeType,
            viewType: node.viewType,
            frame: node.frame,
            absoluteFrame: node.absoluteFrame,
            canBecomeFocused: node.canBecomeFocused,
            isFocused: node.isFocused,
            isHidden: node.isHidden,
            isInteractable: node.isInteractable
        )
    }

    func nodeCropRect(
        node: UINodeSnapshot,
        window: UIWindowSnapshot,
        sourceImage: Image,
        padding: Float,
        selector: UIQuerySelector
    ) throws -> ScreenshotCropRect {
        let windowSize = window.summary.frame.size
        guard windowSize.width > 0, windowSize.height > 0 else {
            throw AdaMCPError.screenshotUnavailable("UI window \(window.summary.windowId) has no measurable size.")
        }

        let paddedFrame = Rect(
            x: node.absoluteFrame.minX - padding,
            y: node.absoluteFrame.minY - padding,
            width: node.absoluteFrame.width + padding * 2,
            height: node.absoluteFrame.height + padding * 2
        )
        let visibleMinX = max(0, paddedFrame.minX)
        let visibleMinY = max(0, paddedFrame.minY)
        let visibleMaxX = min(windowSize.width, paddedFrame.maxX)
        let visibleMaxY = min(windowSize.height, paddedFrame.maxY)
        guard visibleMaxX > visibleMinX, visibleMaxY > visibleMinY else {
            throw AdaMCPError.uiNodeNotVisible(selector.externalValue)
        }

        let scaleX = Double(sourceImage.width) / Double(windowSize.width)
        let scaleY = Double(sourceImage.height) / Double(windowSize.height)
        let minX = max(0, Int(floor(Double(visibleMinX) * scaleX)))
        let minY = max(0, Int(floor(Double(visibleMinY) * scaleY)))
        let maxX = min(sourceImage.width, Int(ceil(Double(visibleMaxX) * scaleX)))
        let maxY = min(sourceImage.height, Int(ceil(Double(visibleMaxY) * scaleY)))
        guard maxX > minX, maxY > minY else {
            throw AdaMCPError.uiNodeNotVisible(selector.externalValue)
        }

        return ScreenshotCropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func doubleArgument(_ arguments: [String: Value], _ name: String) -> Double? {
        arguments[name]?.doubleValue ?? arguments[name]?.intValue.map(Double.init)
    }

    func resolveOptionalUINodeSelector(arguments: [String: Value]) -> UINodeSelector? {
        if let accessibilityIdentifier = arguments["accessibilityIdentifier"]?.stringValue, !accessibilityIdentifier.isEmpty {
            return .accessibilityIdentifier(accessibilityIdentifier)
        }
        if let runtimeID = arguments["runtimeId"]?.stringValue, !runtimeID.isEmpty {
            return .runtimeID(runtimeID)
        }
        return nil
    }

    func resolveOptionalUIQuerySelector(arguments: [String: Value]) -> UIQuerySelector? {
        if let selector = self.resolveOptionalUINodeSelector(arguments: arguments) {
            return .node(selector)
        }
        if let nodeType = arguments["nodeType"]?.stringValue, !nodeType.isEmpty {
            return .nodeType(nodeType)
        }
        if let viewType = arguments["viewType"]?.stringValue, !viewType.isEmpty {
            return .viewType(viewType)
        }
        return nil
    }

    func resolveUINodeSelector(arguments: [String: Value]) throws -> UINodeSelector {
        guard let selector = self.resolveOptionalUINodeSelector(arguments: arguments) else {
            throw AdaMCPError.invalidArguments("Argument 'accessibilityIdentifier' or 'runtimeId' is required.")
        }
        return selector
    }

    func resolveUIQuerySelector(arguments: [String: Value]) throws -> UIQuerySelector {
        guard let selector = self.resolveOptionalUIQuerySelector(arguments: arguments) else {
            throw AdaMCPError.invalidArguments("Argument 'accessibilityIdentifier', 'runtimeId', 'nodeType', or 'viewType' is required.")
        }
        return selector
    }

    func parseUINodeRef(_ value: String) throws -> UINodeSelector {
        if value.hasPrefix("accessibility:") {
            return .accessibilityIdentifier(String(value.dropFirst("accessibility:".count)))
        }
        if value.hasPrefix("runtime:") {
            return .runtimeID(String(value.dropFirst("runtime:".count)))
        }
        throw AdaMCPError.invalidResourceURI("ada://ui/node/{windowId}/\(value)")
    }
}
