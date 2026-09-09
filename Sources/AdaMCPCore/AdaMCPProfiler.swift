import Foundation
import MCP

#if canImport(Darwin)
import Darwin
#endif

/// Coordinates bounded AdaEngine profiling captures on top of the AdaMCP trace recorder.
@MainActor
public final class AdaMCPProfiler {
    private struct ActiveCapture: Sendable {
        let id: String
        let preset: String
        let startedAt: Date
        let durationMilliseconds: Int?
        let frameCount: Int?
        let frameBudgetMilliseconds: Double
        let fileURL: URL
    }

    private let traceRecorder: AdaMCPTraceRecorder?
    private var activeCapture: ActiveCapture?
    private var captures: [String: Value] = [:]
    private var captureOrder: [String] = []
    private var peakResidentBytes: UInt64 = 0
    private var liveLease: AdaMCPTraceLease?
    private var liveLeaseTask: Task<Void, Never>?
    private var captureRefreshTask: Task<Void, Never>?
    private let liveLeaseDuration: Duration

    public init(traceRecorder: AdaMCPTraceRecorder?, liveLeaseDuration: Duration = .seconds(3)) {
        self.traceRecorder = traceRecorder
        self.liveLeaseDuration = max(.milliseconds(1), liveLeaseDuration)
    }

    deinit {
        liveLeaseTask?.cancel()
        captureRefreshTask?.cancel()
        if let activeCapture {
            _ = try? traceRecorder?.tracer.discardFileSession(expectedURL: activeCapture.fileURL)
        }
    }

    public func capabilitiesPayload() -> Value {
        .object([
            "platform": .string(Self.platformName),
            "recording": .bool(traceRecorder?.isInstalledAsGlobalTracer == true && traceRecorder?.tracer.isAutomaticRecordingEnabled == true),
            "presets": .array([
                .object([
                    "name": .string("frame"),
                    "supported": .bool(traceRecorder != nil),
                    "intrusive": .bool(false)
                ]),
                Self.unsupportedPreset("cpuSample", reason: "The xctrace Time Profiler provider is not part of the CPU-first runtime capture."),
                Self.unsupportedPreset("allocations", reason: "The xctrace Allocations provider is not part of the CPU-first runtime capture."),
                Self.unsupportedPreset("gpuFrame", reason: "Metal counters and .gputrace capture are not part of the CPU-first runtime capture.")
            ]),
            "providers": .object([
                "cpuFrame": Self.capability(supported: traceRecorder != nil, provider: "swift-distributed-tracing"),
                "ecsSystems": Self.capability(supported: traceRecorder != nil, provider: "AdaECS spans"),
                "renderGraph": Self.capability(supported: traceRecorder != nil, provider: "AdaRender spans"),
                "display": Self.capability(supported: traceRecorder != nil, provider: "MTLDrawable presentation spans"),
                "memoryFootprint": Self.capability(supported: Self.supportsProcessMemory, provider: "Mach task info"),
                "hangs": Self.capability(supported: false, provider: "unavailable"),
                "allocations": Self.capability(supported: false, provider: "unavailable"),
                "gpuCounters": Self.capability(supported: false, provider: "unavailable"),
                "metalCapture": Self.capability(supported: false, provider: "unavailable"),
                "symbolication": Self.capability(supported: false, provider: "unavailable")
            ])
        ])
    }

    public func liveSnapshotPayload(limit: Int = 120, frameBudgetMilliseconds: Double = 16.67) throws -> Value {
        try refreshCaptureIfNeeded()
        renewLiveRecordingLease()
        let spans = traceRecorder?.tracer.finishedSpans.suffix(max(1, limit * 32)).map(AdaMCPTraceRecorder.spanValue) ?? []
        let residentBytes = Self.currentResidentBytes()
        peakResidentBytes = max(peakResidentBytes, residentBytes)

        return .object([
            "recording": .bool(traceRecorder?.isInstalledAsGlobalTracer == true && traceRecorder?.tracer.isAutomaticRecordingEnabled == true),
            "timestamp": .string(Self.dateFormatter.string(from: Date())),
            "activeCapture": activeCapture.map(activeCaptureValue) ?? .null,
            "memory": .object([
                "footprintBytes": .int(Self.intValue(residentBytes)),
                "peakFootprintBytes": .int(Self.intValue(peakResidentBytes)),
                "residentBytes": .int(Self.intValue(residentBytes)),
                "peakResidentBytes": .int(Self.intValue(peakResidentBytes))
            ]),
            "summary": Self.summaryValue(spans: Array(spans), frameBudgetMilliseconds: frameBudgetMilliseconds)
        ])
    }

    public func startCapture(arguments: [String: Value]) throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        guard activeCapture == nil else {
            throw AdaMCPError.invalidArguments("A profiler capture is already active.")
        }

        let preset = arguments["preset"]?.stringValue ?? "frame"
        guard preset == "frame" else {
            throw AdaMCPError.invalidArguments("Profiler preset '\(preset)' is not available in the CPU-first runtime.")
        }

        let requestedDuration = arguments["durationMs"]?.intValue
        let requestedFrameCount = arguments["frameCount"]?.intValue
        guard requestedDuration == nil || requestedFrameCount == nil else {
            throw AdaMCPError.invalidArguments("Specify either durationMs or frameCount, not both.")
        }
        if let requestedDuration, requestedDuration <= 0 {
            throw AdaMCPError.invalidArguments("durationMs must be greater than zero.")
        }
        if let requestedFrameCount, requestedFrameCount <= 0 {
            throw AdaMCPError.invalidArguments("frameCount must be greater than zero.")
        }

        let startedAt = Date()
        let fileURL = try traceRecorder.tracer.startFileSession()
        let capture = ActiveCapture(
            id: UUID().uuidString.lowercased(),
            preset: preset,
            startedAt: startedAt,
            durationMilliseconds: requestedDuration ?? (requestedFrameCount == nil ? 5_000 : nil),
            frameCount: requestedFrameCount,
            frameBudgetMilliseconds: max(arguments["frameBudgetMs"]?.doubleValue ?? 16.67, 0.1),
            fileURL: fileURL
        )
        activeCapture = capture
        monitorCapture(id: capture.id)
        return activeCaptureValue(capture)
    }

    public func stopCapture(arguments: [String: Value]) throws -> Value {
        guard let activeCapture else {
            throw AdaMCPError.invalidArguments("No profiler capture is active.")
        }
        if let requestedID = arguments["id"]?.stringValue, requestedID != activeCapture.id {
            throw AdaMCPError.invalidArguments("Profiler capture '\(requestedID)' is not active.")
        }
        return try finishCapture(activeCapture)
    }

    public func capturePayload(id: String?) throws -> Value {
        try refreshCaptureIfNeeded()
        if let activeCapture, id == nil || id == activeCapture.id {
            return activeCaptureValue(activeCapture)
        }
        let captureID = id ?? captureOrder.last
        guard let captureID, let capture = captures[captureID] else {
            throw AdaMCPError.resourceNotFound(id ?? "latest profiler capture")
        }
        return capture
    }

    public func captureListPayload() throws -> Value {
        try refreshCaptureIfNeeded()
        let completed = captureOrder.compactMap { captures[$0]?.objectValue?["manifest"] }
        return .object([
            "activeCapture": activeCapture.map(activeCaptureValue) ?? .null,
            "captures": .array(completed)
        ])
    }

    private func refreshCaptureIfNeeded() throws {
        guard let activeCapture else { return }
        guard traceRecorder?.tracer.fileSessionURL == activeCapture.fileURL else {
            throw AdaMCPError.invalidArguments("The profiler's trace file session was stopped or replaced.")
        }
        let elapsedMilliseconds = Int(Date().timeIntervalSince(activeCapture.startedAt) * 1_000)
        let reachedDuration = activeCapture.durationMilliseconds.map { elapsedMilliseconds >= $0 } == true
        let reachedFrameCount: Bool
        if let requestedFrames = activeCapture.frameCount, let traceRecorder {
            // The bounded memory ring may wrap many times during a capture.
            reachedFrameCount = traceRecorder.tracer.fileSessionFrameCount >= requestedFrames
        } else {
            reachedFrameCount = false
        }
        if reachedDuration || reachedFrameCount {
            _ = try finishCapture(activeCapture)
        }
    }

    private func renewLiveRecordingLease() {
        if liveLease == nil { liveLease = traceRecorder?.tracer.acquireRecordingLease() }
        liveLeaseTask?.cancel()
        let duration = liveLeaseDuration
        liveLeaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.liveLease = nil
            self?.liveLeaseTask = nil
        }
    }

    private func monitorCapture(id: String) {
        captureRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                guard let self, self.activeCapture?.id == id else {
                    return
                }
                do {
                    try self.refreshCaptureIfNeeded()
                } catch {
                    self.activeCapture = nil
                    self.captureRefreshTask = nil
                    self.storeCapture(.object([
                        "manifest": .object(["id": .string(id), "state": .string("failed"), "error": .string(String(describing: error))])
                    ]), id: id)
                    return
                }
            }
        }
    }

    private func finishCapture(_ activeCapture: ActiveCapture) throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        let endedAt = Date()
        let spans = try traceRecorder.tracer.stopFileSession(expectedURL: activeCapture.fileURL)
        let summary = Self.summaryValue(spans: spans, frameBudgetMilliseconds: activeCapture.frameBudgetMilliseconds)
        let manifest: Value = .object([
            "id": .string(activeCapture.id),
            "preset": .string(activeCapture.preset),
            "state": .string("completed"),
            "startedAt": .string(Self.dateFormatter.string(from: activeCapture.startedAt)),
            "endedAt": .string(Self.dateFormatter.string(from: endedAt)),
            "durationMs": .double(endedAt.timeIntervalSince(activeCapture.startedAt) * 1_000),
            "frameBudgetMs": .double(activeCapture.frameBudgetMilliseconds),
            "requestedDurationMs": activeCapture.durationMilliseconds.map(Value.int) ?? .null,
            "requestedFrameCount": activeCapture.frameCount.map(Value.int) ?? .null
        ])
        let capture: Value = .object([
            "manifest": manifest,
            "summary": summary,
            "spans": .array(spans),
            "trace": Self.traceEventValue(spans: spans),
            "artifacts": .array([])
        ])

        self.activeCapture = nil
        captureRefreshTask?.cancel()
        captureRefreshTask = nil
        storeCapture(capture, id: activeCapture.id)
        return capture
    }

    private func storeCapture(_ capture: Value, id: String) {
        captures[id] = capture
        captureOrder.append(id)
        if captureOrder.count > 8 {
            let removalCount = captureOrder.count - 8
            let removed = Array(captureOrder.prefix(removalCount))
            captureOrder.removeFirst(removalCount)
            for id in removed {
                captures[id] = nil
            }
        }
    }

    private func activeCaptureValue(_ capture: ActiveCapture) -> Value {
        .object([
            "id": .string(capture.id),
            "preset": .string(capture.preset),
            "state": .string("recording"),
            "startedAt": .string(Self.dateFormatter.string(from: capture.startedAt)),
            "durationMs": capture.durationMilliseconds.map(Value.int) ?? .null,
            "frameCount": capture.frameCount.map(Value.int) ?? .null,
            "frameBudgetMs": .double(capture.frameBudgetMilliseconds)
        ])
    }
}

private extension AdaMCPProfiler {
    struct MetricSpan {
        let traceID: String
        let name: String
        let category: String
        let label: String
        let startNanoseconds: UInt64
        let durationMilliseconds: Double
        let attributes: [String: Value]
        let parentSpanID: String?
    }

    static let dateFormatter = ISO8601DateFormatter()

    static var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }

    static var supportsProcessMemory: Bool {
        #if canImport(Darwin)
        true
        #else
        false
        #endif
    }

    static func unsupportedPreset(_ name: String, reason: String) -> Value {
        .object([
            "name": .string(name),
            "supported": .bool(false),
            "intrusive": .bool(true),
            "reason": .string(reason)
        ])
    }

    static func capability(supported: Bool, provider: String) -> Value {
        .object([
            "supported": .bool(supported),
            "provider": .string(provider)
        ])
    }

    static func summaryValue(spans: [Value], frameBudgetMilliseconds: Double) -> Value {
        let metrics = spans.compactMap(metricSpan)
        let frames = metrics.filter { $0.category == "frame" && $0.parentSpanID == nil }
        let systems = metrics.filter { $0.category == "system" }
        let renderNodes = metrics.filter { $0.category == "render_node" }
        let display = metrics.filter { $0.category == "display" }
        let frameDurations = frames.map(\.durationMilliseconds)
        let displayIntervals = display.compactMap { $0.attributes["ada.display.interval_ms"]?.doubleValue }
        let droppedFrames = display.filter { $0.attributes["ada.display.dropped"]?.boolValue == true }.count
        let totalSystemWorkMilliseconds = systems.reduce(0) { $0 + $1.durationMilliseconds }

        return .object([
            "frameCount": .int(frames.count),
            "fps": .double(average(frameDurations).map { $0 > 0 ? 1_000 / $0 : 0 } ?? 0),
            "frameTime": statisticsValue(frameDurations),
            "frameBudgetMs": .double(frameBudgetMilliseconds),
            "budgetMissCount": .int(frameDurations.filter { $0 > frameBudgetMilliseconds }.count),
            "criticalPathMs": .double(percentile(frameDurations, percentile: 0.95) ?? 0),
            "totalSystemWorkMs": .double(totalSystemWorkMilliseconds),
            "systemHotspots": hotspotValue(systems),
            "renderNodeHotspots": hotspotValue(renderNodes),
            "display": .object([
                "sampleCount": .int(display.count),
                "interval": statisticsValue(displayIntervals),
                "droppedFrameCount": .int(droppedFrames)
            ])
        ])
    }

    static func hotspotValue(_ spans: [MetricSpan]) -> Value {
        let grouped = Dictionary(grouping: spans, by: \.label)
        let hotspots = grouped.map { label, spans -> Value in
            let durations = spans.map(\.durationMilliseconds)
            return .object([
                "name": .string(label),
                "count": .int(spans.count),
                "totalMs": .double(durations.reduce(0, +)),
                "meanMs": .double(average(durations) ?? 0),
                "p95Ms": .double(percentile(durations, percentile: 0.95) ?? 0),
                "maxMs": .double(durations.max() ?? 0)
            ])
        }.sorted {
            ($0.objectValue?["totalMs"]?.doubleValue ?? 0) > ($1.objectValue?["totalMs"]?.doubleValue ?? 0)
        }
        return .array(Array(hotspots.prefix(12)))
    }

    static func statisticsValue(_ values: [Double]) -> Value {
        .object([
            "meanMs": .double(average(values) ?? 0),
            "p50Ms": .double(percentile(values, percentile: 0.50) ?? 0),
            "p95Ms": .double(percentile(values, percentile: 0.95) ?? 0),
            "maxMs": .double(values.max() ?? 0)
        ])
    }

    static func average(_ values: [Double]) -> Double? {
        guard values.isEmpty == false else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard values.isEmpty == false else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * min(max(percentile, 0), 1)).rounded(.up))
        return sorted[index]
    }

    static func metricSpan(_ value: Value) -> MetricSpan? {
        guard let object = value.objectValue,
              let traceID = object["traceId"]?.stringValue,
              let name = object["name"]?.stringValue,
              let start = object["startTimeUnixNano"]?.stringValue.flatMap(UInt64.init),
              let duration = object["durationNano"]?.stringValue.flatMap(Double.init)
        else {
            return nil
        }
        let attributes = object["attributes"]?.objectValue ?? [:]
        let category = attributes["ada.profile.category"]?.stringValue ?? inferredCategory(name: name)
        let label = attributes["ada.system.name"]?.stringValue
            ?? attributes["ada.render.node"]?.stringValue
            ?? attributes["ada.render.graph"]?.stringValue
            ?? name
        return MetricSpan(
            traceID: traceID,
            name: name,
            category: category,
            label: label,
            startNanoseconds: start,
            durationMilliseconds: duration / 1_000_000,
            attributes: attributes,
            parentSpanID: object["parentSpanId"]?.stringValue
        )
    }

    static func inferredCategory(name: String) -> String {
        if name == "AppWorlds.update" { return "frame" }
        if name.hasPrefix("System.execute.") { return "system" }
        if name.hasPrefix("RenderGraph.node.") { return "render_node" }
        if name.hasPrefix("RenderGraph.frame.") { return "render_graph" }
        if name == "Display.present" { return "display" }
        if name.hasPrefix("Scheduler.run.") || name.hasPrefix("World.runScheduler.") { return "scheduler" }
        return "other"
    }

    static func traceEventValue(spans: [Value]) -> Value {
        let events = spans.compactMap(metricSpan).map { span -> Value in
            var arguments = span.attributes
            arguments["traceId"] = .string(span.traceID)
            if let parentSpanID = span.parentSpanID {
                arguments["parentSpanId"] = .string(parentSpanID)
            }
            return .object([
                "name": .string(span.label),
                "cat": .string(span.category),
                "ph": .string("X"),
                "ts": .double(Double(span.startNanoseconds) / 1_000),
                "dur": .double(span.durationMilliseconds * 1_000),
                "pid": .int(1),
                "tid": .int(trackID(for: span)),
                "args": .object(arguments)
            ])
        }
        return .object([
            "displayTimeUnit": .string("ms"),
            "traceEvents": .array(events)
        ])
    }

    static func trackID(for span: MetricSpan) -> Int {
        switch span.category {
        case "frame": 1
        case "scheduler": 2
        case "render_graph": 4
        case "display": 6
        case "system": 1_000 + stableID(span.label)
        case "render_node": 101_000 + stableID(span.label)
        default: 7
        }
    }

    static func stableID(_ value: String) -> Int {
        value.utf8.reduce(0) { partial, byte in
            (partial &* 31 &+ Int(byte)) % 100_000
        }
    }

    static func currentResidentBytes() -> UInt64 {
        #if canImport(Darwin)
        var virtualMemoryInfo = task_vm_info_data_t()
        var virtualMemoryCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let virtualMemoryResult = withUnsafeMutablePointer(to: &virtualMemoryInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(virtualMemoryCount)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &virtualMemoryCount)
            }
        }
        if virtualMemoryResult == KERN_SUCCESS {
            return UInt64(virtualMemoryInfo.phys_footprint)
        }

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        #else
        return 0
        #endif
    }

    static func intValue(_ value: UInt64) -> Int {
        Int(min(value, UInt64(Int.max)))
    }
}
