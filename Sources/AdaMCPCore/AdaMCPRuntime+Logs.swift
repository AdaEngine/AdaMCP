import AdaEngine
import Foundation
import MCP

extension AdaMCPRuntime {
    func logsPayload(arguments: [String: Value]) async throws -> Value {
        let after = arguments["after"]?.intValue ?? 0
        let limit = arguments["limit"]?.intValue ?? 200
        let wait = arguments["waitMs"]?.intValue ?? 0
        guard after >= 0, (1...1000).contains(limit), (0...30_000).contains(wait) else {
            throw AdaMCPError.invalidArguments("Expected after >= 0, limit 1...1000, waitMs 0...30000.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(wait))
        while true {
            try Task.checkCancellation()
            let batch = RuntimeLogStore.shared.read(after: after, limit: limit)
            if !batch.entries.isEmpty || clock.now >= deadline { return try Value(batch) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
