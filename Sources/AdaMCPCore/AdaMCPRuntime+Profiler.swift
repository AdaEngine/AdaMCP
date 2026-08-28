import Foundation
import MCP

extension AdaMCPRuntime {
    func profilerResourcePayload(url: URL, uri: String) throws -> Value {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else {
            throw AdaMCPError.invalidResourceURI(uri)
        }

        switch first {
        case "live":
            return try profiler.liveSnapshotPayload()
        case "captures":
            return try profiler.captureListPayload()
        case "capture":
            guard parts.count == 2 else {
                throw AdaMCPError.invalidResourceURI(uri)
            }
            return try profiler.capturePayload(id: parts[1])
        default:
            throw AdaMCPError.invalidResourceURI(uri)
        }
    }
}
