import Foundation
import InMemoryTracing
import MCP
import Tracing

public struct AdaMCPTracer: Tracer, Sendable {
    public typealias Span = InMemorySpan

    public let idGenerator: InMemoryTracer.IDGenerator
    public let maxFinishedSpanCount: Int
    public let temporaryDirectory: URL

    private let state = State()

    public init(
        idGenerator: InMemoryTracer.IDGenerator = AdaMCPTraceRecorder.makeIDGenerator(),
        maxFinishedSpanCount: Int = 1_000,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.idGenerator = idGenerator
        self.maxFinishedSpanCount = max(0, maxFinishedSpanCount)
        self.temporaryDirectory = temporaryDirectory
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

    public func clearFinishedSpans() {
        state.clearFinishedSpans()
    }

    public func startFileSession() throws -> URL {
        try state.startFileSession(temporaryDirectory: temporaryDirectory)
    }

    public func stopFileSession() throws -> [Value] {
        try state.stopFileSession(deleteFile: true)
    }

    public func discardFileSession() throws -> URL {
        try state.discardFileSession()
    }

    private func finishSpan(_ span: FinishedInMemorySpan, identifiedBy spanContext: InMemorySpanContext) {
        state.finishSpan(span, identifiedBy: spanContext, maxFinishedSpanCount: maxFinishedSpanCount)
    }
}

private extension AdaMCPTracer {
    final class State: @unchecked Sendable {
        private struct FileSession {
            let url: URL
            let handle: FileHandle
        }

        private let lock = NSLock()
        private var activeSpanStorage: [InMemorySpanContext: InMemorySpan] = [:]
        private var finishedSpanStorage: [FinishedInMemorySpan] = []
        private var fileSession: FileSession?
        private var _droppedSpanCount = 0

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
            lock.withLock { finishedSpanStorage }
        }

        func clearFinishedSpans() {
            lock.withLock {
                finishedSpanStorage = []
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
                    finishedSpanStorage.append(span)
                    if finishedSpanStorage.count > maxFinishedSpanCount {
                        let overflow = finishedSpanStorage.count - maxFinishedSpanCount
                        finishedSpanStorage.removeFirst(overflow)
                        _droppedSpanCount += overflow
                    }
                } else {
                    _droppedSpanCount += 1
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
                return url
            }
        }

        func stopFileSession(deleteFile: Bool) throws -> [Value] {
            let session = try closeFileSession()
            defer {
                if deleteFile {
                    try? FileManager.default.removeItem(at: session.url)
                }
            }

            let data = try Data(contentsOf: session.url)
            return try Self.decodeJSONLines(data)
        }

        func discardFileSession() throws -> URL {
            let session = try closeFileSession()
            try? FileManager.default.removeItem(at: session.url)
            return session.url
        }

        private func closeFileSession() throws -> FileSession {
            try lock.withLock {
                guard let session = fileSession else {
                    throw AdaMCPError.traceFileSessionInactive
                }
                fileSession = nil
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
                // File tracing is diagnostic-only; keep the live app running if a write fails.
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

        public init(
            maxFinishedSpanCount: Int = 1_000,
            serviceName: String = "adaengine",
            scopeName: String = "AdaEngine",
            temporaryDirectory: URL = FileManager.default.temporaryDirectory
        ) {
            self.maxFinishedSpanCount = maxFinishedSpanCount
            self.serviceName = serviceName
            self.scopeName = scopeName
            self.temporaryDirectory = temporaryDirectory
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
                temporaryDirectory: configuration.temporaryDirectory
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
                temporaryDirectory: tracer.temporaryDirectory
            )
        )
    }

    public static func activeGlobalRecorder() -> AdaMCPTraceRecorder? {
        guard let tracer = InstrumentationSystem._findInstrument(where: { $0 is AdaMCPTracer }) as? AdaMCPTracer else {
            return nil
        }
        return AdaMCPTraceRecorder(tracer: tracer)
    }

    @discardableResult
    public func installAsGlobalTracerIfPossible() -> Bool {
        if Self.activeGlobalRecorder() != nil {
            return true
        }

        let instrumentName = String(reflecting: type(of: InstrumentationSystem.instrument))
        guard instrumentName == "Instrumentation.NoOpInstrument", InstrumentationSystem.tracer is NoOpTracer else {
            return false
        }

        InstrumentationSystem.bootstrap(self.tracer)
        return true
    }

    public var isInstalledAsGlobalTracer: Bool {
        Self.activeGlobalRecorder() != nil
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
            "recording": .bool(self.isInstalledAsGlobalTracer)
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
                "recording": .bool(self.isInstalledAsGlobalTracer)
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
                UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            },
            nextSpanID: {
                String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
            }
        )
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
