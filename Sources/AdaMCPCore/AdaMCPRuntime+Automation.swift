import Foundation
import MCP
import Yams

extension AdaMCPRuntime {
    static let automationCommands = [
        "setComponent", "removeComponent", "setResource", "removeResource", "sendEvent",
        "tapOn", "scrollTo", "focusOn", "tapEvent", "mouseEvent", "scrollEvent", "keyEvent", "pinchEvent",
        "wait", "stepFrame", "getMetrics", "getLogs"
    ]

    func automationTools() -> [Tool] {
        [
            Tool(name: "automation.capabilities", description: "List scenario commands and qualified writable component, resource and event names.",
                 inputSchema: Self.objectSchema(), annotations: .init(readOnlyHint: true)),
            Tool(name: "automation.run", description: "Run a YAML/JSON scenario supplied as source text, or a steps array. Sequential, stops on first error; earlier steps remain applied. ECS commands require world. Maximum 1000 steps / 1 MiB source. Use adamcp.run_file for a local file.",
                 inputSchema: Self.objectSchema(properties: [
                    "source": ["type": "string"], "steps": ["type": "array", "items": ["type": "object"]]
                 ]), annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false)),
            Tool(name: "logs.read", description: "Read bounded runtime logs after a cursor. waitMs (0–30000) long-polls for new logs. Continue with nextCursor; dropped reports expired entries.",
                 inputSchema: Self.objectSchema(properties: [
                    "after": ["type": "integer"], "limit": ["type": "integer"], "waitMs": ["type": "integer"]
                 ]), annotations: .init(readOnlyHint: true))
        ]
    }

    func automationCapabilities() -> Value {
        ["commands": .array(Self.automationCommands.map(Value.string)),
         "components": .array(registry.componentWriters.keys.sorted().map(Value.string)),
         "resources": .array(registry.resourceWriters.keys.sorted().map(Value.string)),
         "events": .array(registry.eventSenders.keys.sorted().map(Value.string)),
         "commandSchemas": .object(automationCommandSchemas()),
         "typeIdentifier": "qualifiedSwiftName", "requiresWorld": true,
         "execution": "sequential-stop-on-error-no-rollback"]
    }

    func runAutomation(arguments: [String: Value]) async throws -> CallTool.Result {
        guard !automationIsRunning else {
            throw AdaMCPError.invalidArguments("An automation scenario is already running in this runtime.")
        }
        let steps = try parseAutomation(arguments)
        automationIsRunning = true
        defer { automationIsRunning = false }
        var results: [Value] = []
        for (index, step) in steps.enumerated() {
            do {
                try Task.checkCancellation()
                let output = try await executeAutomation(command: step.command, arguments: step.arguments)
                results.append(["index": .int(index), "command": .string(step.command), "result": output])
            } catch {
                let details = (error as? AdaMCPError).map { try? Value($0.payload) } ?? nil
                return try jsonToolResult([
                    "status": "failed", "completedSteps": .int(results.count), "failedStep": .int(index),
                    "command": .string(step.command), "message": .string(error.localizedDescription),
                    "error": details ?? .null, "results": .array(results)
                ], isError: true)
            }
        }
        return try jsonToolResult(["status": "completed", "completedSteps": .int(results.count), "results": .array(results)])
    }

    private func parseAutomation(_ arguments: [String: Value]) throws -> [(command: String, arguments: [String: Value])] {
        guard (arguments["source"] != nil) != (arguments["steps"] != nil) else {
            throw AdaMCPError.invalidArguments("Supply exactly one of 'source' or 'steps'.")
        }
        let value: Value
        if let source = arguments["source"]?.stringValue {
            guard source.utf8.count <= 1_048_576 else { throw AdaMCPError.invalidArguments("Scenario exceeds 1 MiB.") }
            do {
                value = try YAMLDecoder().decode(Value.self, from: source)
            } catch {
                throw AdaMCPError.invalidArguments("Invalid YAML/JSON scenario: \(error.localizedDescription)")
            }
        } else {
            value = arguments["steps"] ?? .null
        }
        guard let steps = value.arrayValue, !steps.isEmpty, steps.count <= 1000 else {
            throw AdaMCPError.invalidArguments("Scenario must be an array of 1–1000 commands.")
        }
        let schemas = automationCommandSchemas()
        return try steps.enumerated().map { index, value in
            guard let object = value.objectValue, object.count == 1,
                  let command = object.keys.first, Self.automationCommands.contains(command),
                  let args = object[command]?.objectValue else {
                throw AdaMCPError.invalidArguments("Step \(index) must contain exactly one supported command with an object payload.")
            }
            if ["setComponent", "removeComponent", "setResource", "removeResource", "sendEvent",
                "tapEvent", "mouseEvent", "scrollEvent", "keyEvent", "pinchEvent"].contains(command) {
                _ = try requiredString(args, "world")
            }
            try validateAutomationArguments(args, schema: schemas[command] ?? .null, step: index)
            return (command, args)
        }
    }

    private func executeAutomation(command: String, arguments: [String: Value]) async throws -> Value {
        switch command {
        case "setComponent", "removeComponent", "setResource", "removeResource", "sendEvent":
            return try await mutationPayload(command: command, arguments: arguments)
        case "tapOn", "scrollTo", "focusOn":
            var selector = arguments
            selector["accessibilityIdentifier"] = .string(try requiredString(arguments, "id"))
            return try await appWorlds.withWorldAccess {
                switch command {
                case "tapOn": return try uiTapNodePayload(arguments: selector)
                case "scrollTo": return try uiScrollToNodePayload(arguments: selector)
                default: return try uiFocusNodePayload(arguments: selector)
                }
            }
        case "tapEvent", "mouseEvent", "scrollEvent", "keyEvent", "pinchEvent":
            return try await inputEventPayload(command: command, arguments: arguments)
        case "wait":
            guard let milliseconds = arguments["milliseconds"]?.intValue, (0...30_000).contains(milliseconds) else {
                throw AdaMCPError.invalidArguments("'milliseconds' must be an integer in 0...30000.")
            }
            try await Task.sleep(for: .milliseconds(milliseconds))
            return ["milliseconds": .int(milliseconds)]
        case "stepFrame":
            guard let frames = arguments["frames"]?.intValue, (1...120).contains(frames) else {
                throw AdaMCPError.invalidArguments("'frames' must be in 1...120.")
            }
            return try await stepFramePayload(frames: frames)
        case "getMetrics":
            return try profiler.liveSnapshotPayload(limit: 120, frameBudgetMilliseconds: 16.67)
        case "getLogs":
            return try await logsPayload(arguments: arguments)
        default:
            throw AdaMCPError.invalidArguments("Unknown command '\(command)'.")
        }
    }
}
