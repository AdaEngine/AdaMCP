import AdaUtils
import Foundation
import InMemoryTracing
import MCP
import Tracing

public struct AdaMCPTracer: Tracer, Sendable {
    public typealias Span = InMemorySpan

    public let idGenerator: InMemoryTracer.IDGenerator
    public let maxFinishedSpanCount: Int
    public let temporaryDirectory: URL

    let performance = AdaMCPPerformanceAccumulator()

    private let state: State
    private let recordingControl: AdaMCPTraceControl

    public init(
        idGenerator: InMemoryTracer.IDGenerator = AdaMCPTraceRecorder.makeIDGenerator(),
        maxFinishedSpanCount: Int = 1_000,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        continuousRecording: Bool = true
    ) {
        self.idGenerator = idGenerator
        self.maxFinishedSpanCount = max(0, maxFinishedSpanCount)
        self.temporaryDirectory = temporaryDirectory
        let control = AdaMCPTraceControl(continuous: continuousRecording)
        self.recordingControl = control
        self.state = State(recordingControl: control)
    }

    /// Whether automatic AdaEngine spans are enabled by continuous mode or a consumer.
    /// Explicit low-level startSpan calls remain available regardless of this setting.
    public var isAutomaticRecordingEnabled: Bool { recordingControl.isEnabled }
    public var isContinuousRecordingEnabled: Bool { recordingControl.isContinuous }

    public func setContinuousRecordingEnabled(_ enabled: Bool) {
        connectRecordingControlIfGlobal()
        recordingControl.setContinuous(enabled)
    }

    public func acquireRecordingLease() -> AdaMCPTraceLease {
        connectRecordingControlIfGlobal()
        return recordingControl.acquireLease()
    }

    fileprivate func installRecordingControl() { recordingControl.install() }

    fileprivate func sharesState(with other: Self) -> Bool { state === other.state }

    fileprivate static func selectedGlobalTracer() -> Self? {
        // SDK withSpan uses the first LegacyTracer; Tracer refines that protocol.
        // A legacy-only provider ahead of AdaMCP must retain ownership as well.
        InstrumentationSystem._findInstrument(where: { $0 is any LegacyTracer }) as? Self
    }

    private func connectRecordingControlIfGlobal() {
        if let global = Self.selectedGlobalTracer(),
           sharesState(with: global) {
            recordingControl.install()
        }
    }

    public func startSpan<Instant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> InMemorySpan where Instant: TracerInstant {
        let parentContext = context()
        let spanContext: InMemorySpanContext

        if let parentSpanContext = parentContext.inMemorySpanContext {
            spanContext = InMemorySpanContext(
                traceID: parentSpanContext.traceID,
                spanID: idGenerator.nextSpanID(),
                parentSpanID: parentSpanContext.spanID
            )
        } else {
            spanContext = InMemorySpanContext(
                traceID: idGenerator.nextTraceID(),
                spanID: idGenerator.nextSpanID(),
                parentSpanID: nil
            )
        }

        var context = parentContext
        context.inMemorySpanContext = spanContext

        let span = InMemorySpan(
            operationName: operationName,
            context: context,
            spanContext: spanContext,
            kind: kind,
            startInstant: instant()
        ) { finishedSpan in
            self.finishSpan(finishedSpan, identifiedBy: spanContext)
        }
        if let target = AdaTrace.profileTargetID {
            span.attributes["ada.profile.target_id"] = target
            span.attributes["ada.profile.frame_root"] = AdaTrace.profileFrameRoot
        }
        state.insertActiveSpan(span, identifiedBy: spanContext)
        return span
    }

    public func activeSpan(identifiedBy context: ServiceContext) -> InMemorySpan? {
        guard let spanContext = context.inMemorySpanContext else {
            return nil
        }
        return state.activeSpan(identifiedBy: spanContext)
    }

    public func forceFlush() {}

    public func inject<Carrier, Inject: Injector>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Carrier == Inject.Carrier {
        guard let spanContext = context.inMemorySpanContext else {
            return
        }
        injector.inject(spanContext.traceID, forKey: InMemoryTracer.traceIDKey, into: &carrier)
        injector.inject(spanContext.spanID, forKey: InMemoryTracer.spanIDKey, into: &carrier)
    }

    public func extract<Carrier, Extract: Extractor>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Carrier == Extract.Carrier {
        guard let traceID = extractor.extract(key: InMemoryTracer.traceIDKey, from: carrier),
              let spanID = extractor.extract(key: InMemoryTracer.spanIDKey, from: carrier) else {
            return
        }

        context.inMemorySpanContext = InMemorySpanContext(traceID: traceID, spanID: spanID, parentSpanID: nil)
    }

    public var finishedSpans: [FinishedInMemorySpan] {
        state.finishedSpanSnapshot()
    }

    public var activeSpans: [InMemorySpan] {
        state.activeSpanSnapshot()
    }

    public var finishedSpanCount: Int {
        state.finishedSpanCount
    }

    public var activeSpanCount: Int {
        state.activeSpanCount
    }

    public var droppedSpanCount: Int {
        state.droppedSpanCount
    }

    public var isFileSessionActive: Bool {
        state.isFileSessionActive
    }

    public var fileSessionURL: URL? {
        state.fileSessionURL
    }

    public var fileSessionFrameCount: Int { state.fileSessionFrameCount }
    func fileSessionFrameCount(targetID: String) -> Int { state.targetFrameCount(targetID) }

    public func clearFinishedSpans() {
        state.clearFinishedSpans()
    }

    public func startFileSession() throws -> URL {
        connectRecordingControlIfGlobal()
        return try state.startFileSession(temporaryDirectory: temporaryDirectory)
    }

    public func stopFileSession() throws -> [Value] {
        connectRecordingControlIfGlobal()
        return try state.stopFileSession(deleteFile: true)
    }

    func stopFileSession(expectedURL: URL) throws -> [Value] {
        try state.stopFileSession(deleteFile: true, expectedURL: expectedURL)
    }

    public func discardFileSession() throws -> URL {
        connectRecordingControlIfGlobal()
        return try state.discardFileSession()
    }

    func discardFileSession(expectedURL: URL) throws -> URL {
        try state.discardFileSession(expectedURL: expectedURL)
    }

    private func finishSpan(_ span: FinishedInMemorySpan, identifiedBy spanContext: InMemorySpanContext) {
        performance.record(span)
        state.finishSpan(span, identifiedBy: spanContext, maxFinishedSpanCount: maxFinishedSpanCount)
    }
}

private extension AdaMCPTracer {
    final class State: @unchecked Sendable {
        private struct FileSession {
            let url: URL
            let handle: FileHandle
            let startedAt = DefaultTracerClock.now.nanosecondsSinceEpoch
            var frameCount = 0
            var targetFrameCounts: [String: Int] = [:]
            var writeError: String?
        }

        private let lock = NSLock()
        private var activeSpanStorage: [InMemorySpanContext: InMemorySpan] = [:]
        private var finishedSpanStorage: [FinishedInMemorySpan] = []
        /// Oldest entry in the bounded ring. All access is protected by `lock`.
        private var finishedSpanStart = 0
        private var fileSession: FileSession?
        private var _droppedSpanCount = 0
        private let recordingControl: AdaMCPTraceControl

        init(recordingControl: AdaMCPTraceControl) { self.recordingControl = recordingControl }

        var finishedSpanCount: Int {
            lock.withLock { finishedSpanStorage.count }
        }

        var activeSpanCount: Int {
            lock.withLock { activeSpanStorage.count }
        }

        var droppedSpanCount: Int {
            lock.withLock { _droppedSpanCount }
        }

        var isFileSessionActive: Bool {
            lock.withLock { fileSession != nil }
        }

        var fileSessionURL: URL? {
            lock.withLock { fileSession?.url }
        }

        var fileSessionFrameCount: Int { lock.withLock { fileSession?.frameCount ?? 0 } }
        func targetFrameCount(_ id: String) -> Int { lock.withLock { fileSession?.targetFrameCounts[id] ?? 0 } }

        func insertActiveSpan(_ span: InMemorySpan, identifiedBy spanContext: InMemorySpanContext) {
            lock.withLock {
                activeSpanStorage[spanContext] = span
            }
        }

        func activeSpan(identifiedBy spanContext: InMemorySpanContext) -> InMemorySpan? {
            lock.withLock { activeSpanStorage[spanContext] }
        }

        func activeSpanSnapshot() -> [InMemorySpan] {
            lock.withLock { Array(activeSpanStorage.values) }
        }

        func finishedSpanSnapshot() -> [FinishedInMemorySpan] {
            lock.withLock {
                guard finishedSpanStart != 0 else {
                    return finishedSpanStorage
                }
                var snapshot: [FinishedInMemorySpan] = []
                snapshot.reserveCapacity(finishedSpanStorage.count)
                snapshot.append(contentsOf: finishedSpanStorage[finishedSpanStart...])
                snapshot.append(contentsOf: finishedSpanStorage[..<finishedSpanStart])
                return snapshot
            }
        }

        func clearFinishedSpans() {
            lock.withLock {
                finishedSpanStorage = []
                finishedSpanStart = 0
                _droppedSpanCount = 0
            }
        }

        func finishSpan(
            _ span: FinishedInMemorySpan,
            identifiedBy spanContext: InMemorySpanContext,
            maxFinishedSpanCount: Int
        ) {
            lock.withLock {
                activeSpanStorage[spanContext] = nil
                if maxFinishedSpanCount > 0 {
                    if finishedSpanStorage.count < maxFinishedSpanCount {
                        finishedSpanStorage.append(span)
                    } else {
                        finishedSpanStorage[finishedSpanStart] = span
                        finishedSpanStart += 1
                        if finishedSpanStart == finishedSpanStorage.count {
                            finishedSpanStart = 0
                        }
                        _droppedSpanCount += 1
                    }
                } else {
                    _droppedSpanCount += 1
                }

                if let session = fileSession,
                   span.operationName == "AppWorlds.update", span.parentSpanID == nil,
                   span.startInstant.nanosecondsSinceEpoch >= session.startedAt {
                    fileSession?.frameCount += 1
                }
                if let session = fileSession, span.operationName == "AppWorlds.update",
                   span.startInstant.nanosecondsSinceEpoch >= session.startedAt,
                   case .string(let targetID) = span.attributes["ada.profile.target_id"]?.toSpanAttribute(),
                   case .bool(true) = span.attributes["ada.profile.frame_root"]?.toSpanAttribute() {
                    fileSession?.targetFrameCounts[targetID, default: 0] += 1
                }
                if let fileSession {
                    self.append(span, to: fileSession.handle)
                }
            }
        }

        func startFileSession(temporaryDirectory: URL) throws -> URL {
            try lock.withLock {
                guard fileSession == nil else {
                    throw AdaMCPError.traceFileSessionAlreadyActive
                }

                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                let url = temporaryDirectory.appendingPathComponent(
                    "adamcp-trace-\(UUID().uuidString.lowercased()).jsonl"
                )
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                fileSession = FileSession(url: url, handle: handle)
                recordingControl.setFileActive(true)
                return url
            }
        }

        func stopFileSession(deleteFile: Bool, expectedURL: URL? = nil) throws -> [Value] {
            let session = try closeFileSession(expectedURL: expectedURL)
            defer {
                if deleteFile {
                    try? FileManager.default.removeItem(at: session.url)
                }
            }

            if let error = session.writeError { throw AdaMCPError.invalidArguments("Trace write failed: \(error)") }
            let data = try Data(contentsOf: session.url)
            return try Self.decodeJSONLines(data)
        }

        func discardFileSession(expectedURL: URL? = nil) throws -> URL {
            let session = try closeFileSession(expectedURL: expectedURL)
            try? FileManager.default.removeItem(at: session.url)
            return session.url
        }

        private func closeFileSession(expectedURL: URL? = nil) throws -> FileSession {
            try lock.withLock {
                guard let session = fileSession else {
                    throw AdaMCPError.traceFileSessionInactive
                }
                guard expectedURL == nil || expectedURL == session.url else {
                    throw AdaMCPError.invalidArguments("The profiler's trace file session was replaced.")
                }
                fileSession = nil
                recordingControl.setFileActive(false)
                try session.handle.synchronize()
                try session.handle.close()
                return session
            }
        }

        private func append(_ span: FinishedInMemorySpan, to handle: FileHandle) {
            do {
                let value = AdaMCPTraceRecorder.spanValue(for: span)
                var data = try JSONEncoder().encode(value)
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                // Preserve runtime execution, but report incomplete capture data to its consumer.
                fileSession?.writeError = String(describing: error)
            }
        }

        private static func decodeJSONLines(_ data: Data) throws -> [Value] {
            guard !data.isEmpty else {
                return []
            }

            return try String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    let lineData = Data(line.utf8)
                    return try JSONDecoder().decode(Value.self, from: lineData)
                }
        }
    }
}

public struct AdaMCPTraceRecorder: Sendable {
    public struct Configuration: Sendable {
        public let maxFinishedSpanCount: Int
        public let serviceName: String
        public let scopeName: String
        public let temporaryDirectory: URL
        public let continuousRecording: Bool

        public init(
            maxFinishedSpanCount: Int = 1_000,
            serviceName: String = "adaengine",
            scopeName: String = "AdaEngine",
            temporaryDirectory: URL = FileManager.default.temporaryDirectory,
            continuousRecording: Bool = true
        ) {
            self.maxFinishedSpanCount = maxFinishedSpanCount
            self.serviceName = serviceName
            self.scopeName = scopeName
            self.temporaryDirectory = temporaryDirectory
            self.continuousRecording = continuousRecording
        }
    }

    public let tracer: AdaMCPTracer
    public let configuration: Configuration

    public var serviceName: String { configuration.serviceName }
    public var scopeName: String { configuration.scopeName }

    public init(
        tracer: AdaMCPTracer,
        configuration: Configuration = .init()
    ) {
        self.tracer = tracer
        self.configuration = configuration
    }

    public init(configuration: Configuration = .init()) {
        self.init(
            tracer: AdaMCPTracer(
                idGenerator: AdaMCPTraceRecorder.makeIDGenerator(),
                maxFinishedSpanCount: configuration.maxFinishedSpanCount,
                temporaryDirectory: configuration.temporaryDirectory,
                continuousRecording: configuration.continuousRecording
            ),
            configuration: configuration
        )
    }

    public init(
        tracer: AdaMCPTracer,
        serviceName: String = "adaengine",
        scopeName: String = "AdaEngine"
    ) {
        self.init(
            tracer: tracer,
            configuration: .init(
                maxFinishedSpanCount: tracer.maxFinishedSpanCount,
                serviceName: serviceName,
                scopeName: scopeName,
                temporaryDirectory: tracer.temporaryDirectory,
                continuousRecording: tracer.isContinuousRecordingEnabled
            )
        )
    }

    public static func activeGlobalRecorder() -> AdaMCPTraceRecorder? {
        // Follow the SDK's selected tracer, not an inactive tracing instrument
        // later in a MultiplexInstrument. Its policy must not disable a foreign provider.
        guard let tracer = AdaMCPTracer.selectedGlobalTracer() else {
            return nil
        }
        tracer.installRecordingControl()
        return AdaMCPTraceRecorder(tracer: tracer)
    }

    @discardableResult
    public func installAsGlobalTracerIfPossible() -> Bool {
        if let active = Self.activeGlobalRecorder() {
            return tracer.sharesState(with: active.tracer)
        }

        let instrumentName = String(reflecting: type(of: InstrumentationSystem.instrument))
        guard instrumentName == "Instrumentation.NoOpInstrument", InstrumentationSystem.tracer is NoOpTracer else {
            return false
        }

        InstrumentationSystem.bootstrap(self.tracer)
        tracer.installRecordingControl()
        return true
    }

    public var isInstalledAsGlobalTracer: Bool {
        guard let active = Self.activeGlobalRecorder() else {
            return false
        }
        return tracer.sharesState(with: active.tracer)
    }

    public var finishedSpanCount: Int {
        tracer.finishedSpanCount
    }

    public var activeSpanCount: Int {
        tracer.activeSpanCount
    }

    public var droppedSpanCount: Int {
        tracer.droppedSpanCount
    }

    public func clearFinishedSpans() {
        tracer.clearFinishedSpans()
    }

    public func statusPayload() -> Value {
        .object([
            "memory": .object([
                "maxFinishedSpanCount": .int(tracer.maxFinishedSpanCount),
                "finishedSpanCount": .int(tracer.finishedSpanCount),
                "activeSpanCount": .int(tracer.activeSpanCount),
                "droppedSpanCount": .int(tracer.droppedSpanCount)
            ]),
            "fileSession": .object([
                "active": .bool(tracer.isFileSessionActive),
                "path": tracer.fileSessionURL.map { .string($0.path) } ?? .null
            ]),
            "recording": .bool(self.isInstalledAsGlobalTracer && tracer.isAutomaticRecordingEnabled),
            "continuousRecording": .bool(tracer.isContinuousRecordingEnabled)
        ])
    }

    public func startFilePayload() throws -> Value {
        let url = try tracer.startFileSession()
        return .object([
            "fileSession": .object([
                "active": .bool(true),
                "path": .string(url.path)
            ])
        ])
    }

    public func stopFilePayload(arguments: [String: Value] = [:]) throws -> Value {
        let spans = try tracer.stopFileSession()
        return self.spanPayload(spans: self.filteredSpanValues(spans, arguments: arguments))
    }

    public func discardFilePayload() throws -> Value {
        let url = try tracer.discardFileSession()
        return .object([
            "deletedPath": .string(url.path),
            "fileSession": .object(["active": .bool(false)])
        ])
    }

    public func spansPayload(arguments: [String: Value] = [:]) -> Value {
        let clearAfterRead = arguments["clearAfterRead"]?.boolValue ?? false
        let spans = self.filteredFinishedSpans(arguments: arguments)
        let spanValues = spans.map { Self.spanValue(for: $0) }
        if clearAfterRead {
            tracer.clearFinishedSpans()
        }

        return self.spanPayload(spans: spanValues)
    }

    private func spanPayload(spans spanValues: [Value]) -> Value {
        return .object([
            "summary": .object([
                "finishedSpanCount": .int(spanValues.count),
                "activeSpanCount": .int(tracer.activeSpanCount),
                "droppedSpanCount": .int(tracer.droppedSpanCount),
                "maxFinishedSpanCount": .int(tracer.maxFinishedSpanCount),
                "recording": .bool(self.isInstalledAsGlobalTracer && tracer.isAutomaticRecordingEnabled)
            ]),
            "spans": .array(spanValues)
        ])
    }

    public func otlpPayload(arguments: [String: Value] = [:]) -> Value {
        let clearAfterExport = arguments["clearAfterExport"]?.boolValue ?? false
        let spans = self.filteredFinishedSpans(arguments: arguments)
        let payload = self.makeOTLPPayload(spans: spans)
        if clearAfterExport {
            tracer.clearFinishedSpans()
        }
        return payload
    }

    public static func makeIDGenerator() -> InMemoryTracer.IDGenerator {
        InMemoryTracer.IDGenerator(
            nextTraceID: {
                hexadecimalUUID(byteCount: 16)
            },
            nextSpanID: {
                hexadecimalUUID(byteCount: 8)
            }
        )
    }

    /// Encodes UUID bytes directly, without intermediate formatted/replaced strings.
    private static func hexadecimalUUID(byteCount: Int) -> String {
        let uuid = UUID().uuid
        return withUnsafeBytes(of: uuid) { bytes in
            String(unsafeUninitializedCapacity: byteCount * 2) { output in
                // Callers select 8 or 16 bytes from the UUID's 16-byte tuple;
                // every byte of the returned UTF-8 buffer is initialized here.
                for index in 0..<byteCount {
                    let high = bytes[index] >> 4
                    let low = bytes[index] & 0x0f
                    output[index * 2] = high < 10 ? 48 + high : 87 + high
                    output[index * 2 + 1] = low < 10 ? 48 + low : 87 + low
                }
                return byteCount * 2
            }
        }
    }

    private func filteredFinishedSpans(arguments: [String: Value]) -> [FinishedInMemorySpan] {
        var spans = tracer.finishedSpans

        if let traceID = arguments["traceId"]?.stringValue, !traceID.isEmpty {
            spans = spans.filter { $0.traceID == traceID }
        }

        if let nameContains = arguments["nameContains"]?.stringValue, !nameContains.isEmpty {
            spans = spans.filter { $0.operationName.localizedCaseInsensitiveContains(nameContains) }
        }

        if let limit = arguments["limit"]?.intValue, limit > 0, spans.count > limit {
            spans = Array(spans.suffix(limit))
        }

        return spans
    }

    private func filteredSpanValues(_ spans: [Value], arguments: [String: Value]) -> [Value] {
        var spans = spans

        if let traceID = arguments["traceId"]?.stringValue, !traceID.isEmpty {
            spans = spans.filter { $0.objectValue?["traceId"]?.stringValue == traceID }
        }

        if let nameContains = arguments["nameContains"]?.stringValue, !nameContains.isEmpty {
            spans = spans.filter {
                $0.objectValue?["name"]?.stringValue?.localizedCaseInsensitiveContains(nameContains) == true
            }
        }

        if let limit = arguments["limit"]?.intValue, limit > 0, spans.count > limit {
            spans = Array(spans.suffix(limit))
        }

        return spans
    }

    static func spanValue(for span: FinishedInMemorySpan) -> Value {
        .object([
            "traceId": .string(span.traceID),
            "spanId": .string(span.spanID),
            "parentSpanId": span.parentSpanID.map(Value.string) ?? .null,
            "name": .string(span.operationName),
            "kind": .string(Self.kindName(span.kind)),
            "startTimeUnixNano": .string(String(span.startInstant.nanosecondsSinceEpoch)),
            "endTimeUnixNano": .string(String(span.endInstant.nanosecondsSinceEpoch)),
            "durationNano": .string(String(span.endInstant.nanosecondsSinceEpoch - span.startInstant.nanosecondsSinceEpoch)),
            "attributes": Self.nativeAttributesValue(span.attributes),
            "events": .array(span.events.map(Self.eventValue)),
            "links": .array(span.links.map(Self.linkValue)),
            "errors": .array(span.errors.map(Self.errorValue)),
            "status": Self.statusValue(span.status)
        ])
    }

    private func makeOTLPPayload(spans: [FinishedInMemorySpan]) -> Value {
        .object([
            "resourceSpans": .array([
                .object([
                    "resource": .object([
                        "attributes": .array([
                            self.otlpKeyValue("service.name", .string(serviceName)),
                            self.otlpKeyValue("telemetry.sdk.language", .string("swift")),
                            self.otlpKeyValue("telemetry.sdk.name", .string("AdaMCP"))
                        ])
                    ]),
                    "scopeSpans": .array([
                        .object([
                            "scope": .object([
                                "name": .string(scopeName)
                            ]),
                            "spans": .array(spans.map(self.otlpSpanValue))
                        ])
                    ])
                ])
            ])
        ])
    }

    private func otlpSpanValue(_ span: FinishedInMemorySpan) -> Value {
        var payload: [String: Value] = [
            "traceId": .string(span.traceID),
            "spanId": .string(span.spanID),
            "name": .string(span.operationName),
            "kind": .string(self.otlpKindName(span.kind)),
            "startTimeUnixNano": .string(String(span.startInstant.nanosecondsSinceEpoch)),
            "endTimeUnixNano": .string(String(span.endInstant.nanosecondsSinceEpoch)),
            "attributes": self.otlpAttributesValue(span.attributes),
            "events": .array(span.events.map(self.otlpEventValue) + span.errors.map(self.otlpErrorEventValue)),
            "links": .array(span.links.map(self.otlpLinkValue)),
            "status": self.otlpStatusValue(span.status)
        ]

        if let parentSpanID = span.parentSpanID {
            payload["parentSpanId"] = .string(parentSpanID)
        }

        return .object(payload)
    }

    private static func nativeAttributesValue(_ attributes: SpanAttributes) -> Value {
        var payload: [String: Value] = [:]
        attributes.forEach { key, attribute in
            payload[key] = Self.nativeAttributeValue(attribute)
        }
        return .object(payload)
    }

    private static func nativeAttributeValue(_ attribute: SpanAttribute) -> Value {
        switch attribute {
        case .int32(let value):
            return .int(Int(value))
        case .int64(let value):
            return .string(String(value))
        case .int32Array(let value):
            return .array(value.map { .int(Int($0)) })
        case .int64Array(let value):
            return .array(value.map { .string(String($0)) })
        case .double(let value):
            return .double(value)
        case .doubleArray(let value):
            return .array(value.map(Value.double))
        case .bool(let value):
            return .bool(value)
        case .boolArray(let value):
            return .array(value.map(Value.bool))
        case .string(let value):
            return .string(value)
        case .stringArray(let value):
            return .array(value.map(Value.string))
        case .stringConvertible(let value):
            return .string(String(describing: value))
        case .stringConvertibleArray(let value):
            return .array(value.map { .string(String(describing: $0)) })
        default:
            return .string(String(describing: attribute))
        }
    }

    private func otlpAttributesValue(_ attributes: SpanAttributes) -> Value {
        var payload: [Value] = []
        attributes.forEach { key, attribute in
            payload.append(self.otlpKeyValue(key, attribute))
        }
        return .array(payload.sorted { lhs, rhs in
            (lhs.objectValue?["key"]?.stringValue ?? "") < (rhs.objectValue?["key"]?.stringValue ?? "")
        })
    }

    private func otlpKeyValue(_ key: String, _ attribute: SpanAttribute) -> Value {
        .object([
            "key": .string(key),
            "value": self.otlpAnyValue(attribute)
        ])
    }

    private func otlpAnyValue(_ attribute: SpanAttribute) -> Value {
        switch attribute {
        case .int32(let value):
            return .object(["intValue": .int(Int(value))])
        case .int64(let value):
            return .object(["intValue": .string(String(value))])
        case .int32Array(let value):
            return .object(["arrayValue": .object(["values": .array(value.map { .object(["intValue": .int(Int($0))]) })])])
        case .int64Array(let value):
            return .object(["arrayValue": .object(["values": .array(value.map { .object(["intValue": .string(String($0))]) })])])
        case .double(let value):
            return .object(["doubleValue": .double(value)])
        case .doubleArray(let value):
            return .object(["arrayValue": .object(["values": .array(value.map { .object(["doubleValue": .double($0)]) })])])
        case .bool(let value):
            return .object(["boolValue": .bool(value)])
        case .boolArray(let value):
            return .object(["arrayValue": .object(["values": .array(value.map { .object(["boolValue": .bool($0)]) })])])
        case .string(let value):
            return .object(["stringValue": .string(value)])
        case .stringArray(let value):
            return .object(["arrayValue": .object(["values": .array(value.map { .object(["stringValue": .string($0)]) })])])
        case .stringConvertible(let value):
            return .object(["stringValue": .string(String(describing: value))])
        case .stringConvertibleArray(let value):
            return .object([
                "arrayValue": .object([
                    "values": .array(value.map { .object(["stringValue": .string(String(describing: $0))]) })
                ])
            ])
        default:
            return .object(["stringValue": .string(String(describing: attribute))])
        }
    }

    private static func eventValue(_ event: SpanEvent) -> Value {
        .object([
            "name": .string(event.name),
            "timeUnixNano": .string(String(event.nanosecondsSinceEpoch)),
            "attributes": Self.nativeAttributesValue(event.attributes)
        ])
    }

    private func otlpEventValue(_ event: SpanEvent) -> Value {
        .object([
            "name": .string(event.name),
            "timeUnixNano": .string(String(event.nanosecondsSinceEpoch)),
            "attributes": self.otlpAttributesValue(event.attributes)
        ])
    }

    private static func errorValue(_ error: InMemorySpan.RecordedError) -> Value {
        .object([
            "message": .string(error.error.localizedDescription),
            "timeUnixNano": .string(String(error.instant.nanosecondsSinceEpoch)),
            "attributes": Self.nativeAttributesValue(error.attributes)
        ])
    }

    private func otlpErrorEventValue(_ error: InMemorySpan.RecordedError) -> Value {
        var attributes = error.attributes
        attributes["exception.type"] = String(reflecting: type(of: error.error))
        attributes["exception.message"] = error.error.localizedDescription
        return .object([
            "name": .string("exception"),
            "timeUnixNano": .string(String(error.instant.nanosecondsSinceEpoch)),
            "attributes": self.otlpAttributesValue(attributes)
        ])
    }

    private static func linkValue(_ link: SpanLink) -> Value {
        guard let context = link.context.inMemorySpanContext else {
            return .object([
                "traceId": .null,
                "spanId": .null,
                "attributes": Self.nativeAttributesValue(link.attributes)
            ])
        }
        return .object([
            "traceId": .string(context.traceID),
            "spanId": .string(context.spanID),
            "attributes": Self.nativeAttributesValue(link.attributes)
        ])
    }

    private func otlpLinkValue(_ link: SpanLink) -> Value {
        guard let context = link.context.inMemorySpanContext else {
            return .object([
                "attributes": self.otlpAttributesValue(link.attributes)
            ])
        }
        return .object([
            "traceId": .string(context.traceID),
            "spanId": .string(context.spanID),
            "attributes": self.otlpAttributesValue(link.attributes)
        ])
    }

    private static func statusValue(_ status: SpanStatus?) -> Value {
        guard let status else {
            return .object(["code": .string("unset")])
        }
        return .object([
            "code": .string(Self.statusCodeName(status.code)),
            "message": status.message.map(Value.string) ?? .null
        ])
    }

    private func otlpStatusValue(_ status: SpanStatus?) -> Value {
        guard let status else {
            return .object(["code": .string("STATUS_CODE_UNSET")])
        }
        var payload: [String: Value] = [
            "code": .string(self.otlpStatusCodeName(status.code))
        ]
        if let message = status.message {
            payload["message"] = .string(message)
        }
        return .object(payload)
    }

    private static func kindName(_ kind: SpanKind) -> String {
        switch kind {
        case .server:
            return "server"
        case .client:
            return "client"
        case .producer:
            return "producer"
        case .consumer:
            return "consumer"
        case .internal:
            return "internal"
        }
    }

    private func otlpKindName(_ kind: SpanKind) -> String {
        "SPAN_KIND_\(Self.kindName(kind).uppercased())"
    }

    private static func statusCodeName(_ code: SpanStatus.Code) -> String {
        switch code {
        case .ok:
            return "ok"
        case .error:
            return "error"
        }
    }

    private func otlpStatusCodeName(_ code: SpanStatus.Code) -> String {
        switch code {
        case .ok:
            return "STATUS_CODE_OK"
        case .error:
            return "STATUS_CODE_ERROR"
        }
    }
}
