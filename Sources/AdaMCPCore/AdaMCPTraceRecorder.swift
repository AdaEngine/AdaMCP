import Foundation
import InMemoryTracing
import MCP
import Tracing

public struct AdaMCPTraceRecorder: Sendable {
    public let tracer: InMemoryTracer
    public let serviceName: String
    public let scopeName: String

    public init(
        tracer: InMemoryTracer = InMemoryTracer(idGenerator: AdaMCPTraceRecorder.makeIDGenerator()),
        serviceName: String = "adaengine",
        scopeName: String = "AdaEngine"
    ) {
        self.tracer = tracer
        self.serviceName = serviceName
        self.scopeName = scopeName
    }

    public static func activeGlobalRecorder() -> AdaMCPTraceRecorder? {
        guard let tracer = InstrumentationSystem._findInstrument(where: { $0 is InMemoryTracer }) as? InMemoryTracer else {
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
        tracer.finishedSpans.count
    }

    public var activeSpanCount: Int {
        tracer.activeSpans.count
    }

    public func clearFinishedSpans() {
        tracer.clearFinishedSpans()
    }

    public func spansPayload(arguments: [String: Value] = [:]) -> Value {
        let clearAfterRead = arguments["clearAfterRead"]?.boolValue ?? false
        let spans = self.filteredFinishedSpans(arguments: arguments)
        let spanValues = spans.map { self.spanValue($0) }
        if clearAfterRead {
            tracer.clearFinishedSpans()
        }

        return .object([
            "summary": .object([
                "finishedSpanCount": .int(spans.count),
                "activeSpanCount": .int(tracer.activeSpans.count),
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

    private func spanValue(_ span: FinishedInMemorySpan) -> Value {
        .object([
            "traceId": .string(span.traceID),
            "spanId": .string(span.spanID),
            "parentSpanId": span.parentSpanID.map(Value.string) ?? .null,
            "name": .string(span.operationName),
            "kind": .string(self.kindName(span.kind)),
            "startTimeUnixNano": .string(String(span.startInstant.nanosecondsSinceEpoch)),
            "endTimeUnixNano": .string(String(span.endInstant.nanosecondsSinceEpoch)),
            "durationNano": .string(String(span.endInstant.nanosecondsSinceEpoch - span.startInstant.nanosecondsSinceEpoch)),
            "attributes": self.nativeAttributesValue(span.attributes),
            "events": .array(span.events.map(self.eventValue)),
            "links": .array(span.links.map(self.linkValue)),
            "errors": .array(span.errors.map(self.errorValue)),
            "status": self.statusValue(span.status)
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

    private func nativeAttributesValue(_ attributes: SpanAttributes) -> Value {
        var payload: [String: Value] = [:]
        attributes.forEach { key, attribute in
            payload[key] = self.nativeAttributeValue(attribute)
        }
        return .object(payload)
    }

    private func nativeAttributeValue(_ attribute: SpanAttribute) -> Value {
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

    private func eventValue(_ event: SpanEvent) -> Value {
        .object([
            "name": .string(event.name),
            "timeUnixNano": .string(String(event.nanosecondsSinceEpoch)),
            "attributes": self.nativeAttributesValue(event.attributes)
        ])
    }

    private func otlpEventValue(_ event: SpanEvent) -> Value {
        .object([
            "name": .string(event.name),
            "timeUnixNano": .string(String(event.nanosecondsSinceEpoch)),
            "attributes": self.otlpAttributesValue(event.attributes)
        ])
    }

    private func errorValue(_ error: InMemorySpan.RecordedError) -> Value {
        .object([
            "message": .string(error.error.localizedDescription),
            "timeUnixNano": .string(String(error.instant.nanosecondsSinceEpoch)),
            "attributes": self.nativeAttributesValue(error.attributes)
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

    private func linkValue(_ link: SpanLink) -> Value {
        guard let context = link.context.inMemorySpanContext else {
            return .object([
                "traceId": .null,
                "spanId": .null,
                "attributes": self.nativeAttributesValue(link.attributes)
            ])
        }
        return .object([
            "traceId": .string(context.traceID),
            "spanId": .string(context.spanID),
            "attributes": self.nativeAttributesValue(link.attributes)
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

    private func statusValue(_ status: SpanStatus?) -> Value {
        guard let status else {
            return .object(["code": .string("unset")])
        }
        return .object([
            "code": .string(self.statusCodeName(status.code)),
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

    private func kindName(_ kind: SpanKind) -> String {
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
        "SPAN_KIND_\(self.kindName(kind).uppercased())"
    }

    private func statusCodeName(_ code: SpanStatus.Code) -> String {
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
