import Foundation
import MCP

extension AdaMCPRuntime {
    func traceSetEnabledPayload(arguments: [String: Value]) throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        guard let enabled = arguments["enabled"]?.boolValue else {
            throw AdaMCPError.invalidArguments("enabled must be a boolean.")
        }
        traceRecorder.tracer.setContinuousRecordingEnabled(enabled)
        return traceRecorder.statusPayload()
    }

    func traceSpansPayload(arguments: [String: Value]) throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        return traceRecorder.spansPayload(arguments: arguments)
    }

    func traceOTLPPayload(arguments: [String: Value]) throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        return traceRecorder.otlpPayload(arguments: arguments)
    }

    func traceClearPayload() throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        let clearedCount = traceRecorder.finishedSpanCount
        traceRecorder.clearFinishedSpans()
        return .object([
            "clearedSpanCount": .int(clearedCount),
            "activeSpanCount": .int(traceRecorder.activeSpanCount)
        ])
    }

    func traceStatusPayload() throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        return traceRecorder.statusPayload()
    }

    func traceStartFilePayload() throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        return try traceRecorder.startFilePayload()
    }

    func traceStopFilePayload(arguments: [String: Value]) throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        return try traceRecorder.stopFilePayload(arguments: arguments)
    }

    func traceDiscardFilePayload() throws -> Value {
        guard let traceRecorder else {
            throw AdaMCPError.tracingUnavailable
        }
        return try traceRecorder.discardFilePayload()
    }

    func traceResourcePayload(url: URL, uri: String) throws -> Value {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let format = parts.first else {
            throw AdaMCPError.invalidResourceURI(uri)
        }

        switch format {
        case "spans":
            return try self.traceSpansPayload(arguments: [:])
        case "otlp":
            return try self.traceOTLPPayload(arguments: [:])
        default:
            throw AdaMCPError.invalidResourceURI(uri)
        }
    }
}
