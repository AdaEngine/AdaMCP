import MCP

extension AdaMCPRuntime {
    /// Schemas are returned through MCP so a client can author scenarios without filesystem documentation.
    func automationCommandSchemas() -> [String: Value] {
        let string: Value = ["type": "string", "minLength": 1]
        let integer: Value = ["type": "integer"]
        let number: Value = ["type": "number"]
        let world: Value = ["type": "string", "minLength": 1, "description": "Exact name from world.list_worlds; required for mutations."]
        let type: Value = ["type": "string", "minLength": 1, "description": "Qualified Swift name from automation.capabilities."]
        let modifiers: Value = ["type": "array", "items": ["type": "string", "enum": ["shift", "control", "alt", "main", "capsLock"]]]
        let phase: Value = ["type": "string", "enum": ["began", "changed", "ended", "cancelled"]]
        var schemas: [String: Value] = [:]
        for command in ["setComponent", "removeComponent", "setResource", "removeResource", "sendEvent"] {
            var fields: [String: Value] = ["world": world, "type": type]
            if command.hasSuffix("Component") { fields["entity"] = integer }
            if command.hasPrefix("set") || command == "sendEvent" { fields["value"] = .object([:]) }
            schemas[command] = strictSchema(fields, required: fields.keys.sorted())
        }
        for command in ["tapOn", "scrollTo", "focusOn"] {
            schemas[command] = strictSchema(["id": string, "windowId": integer], required: ["id"])
        }
        for command in ["tapEvent", "mouseEvent", "scrollEvent", "keyEvent", "pinchEvent"] {
            var fields: [String: Value] = ["world": world, "windowId": integer]
            var required = ["world", "windowId"]
            if command == "keyEvent" {
                fields["key"] = string
                fields["status"] = ["type": "string", "enum": ["down", "up"]]
                required += ["key", "status"]
            } else {
                fields["x"] = number
                fields["y"] = number
                required += ["x", "y"]
                if command != "tapEvent" {
                    fields["phase"] = phase
                    required.append("phase")
                }
                if command == "pinchEvent" {
                    fields["scale"] = number
                    required.append("scale")
                } else {
                    fields["button"] = ["type": "string", "enum": ["left", "right", "middle", "none"]]
                }
                if command == "scrollEvent" {
                    fields["deltaX"] = number
                    fields["deltaY"] = number
                    required += ["deltaX", "deltaY"]
                }
            }
            if command != "pinchEvent" { fields["modifiers"] = modifiers }
            schemas[command] = strictSchema(fields, required: required)
        }
        schemas["wait"] = strictSchema(["milliseconds": ["type": "integer", "minimum": 0, "maximum": 30000]], required: ["milliseconds"])
        schemas["stepFrame"] = strictSchema(["frames": ["type": "integer", "minimum": 1, "maximum": 120]], required: ["frames"])
        schemas["getMetrics"] = strictSchema([:], required: [])
        schemas["getLogs"] = strictSchema([
            "after": ["type": "integer", "minimum": 0],
            "limit": ["type": "integer", "minimum": 1, "maximum": 1000],
            "waitMs": ["type": "integer", "minimum": 0, "maximum": 30000]
        ], required: [])
        return schemas
    }

    func validateAutomationArguments(_ arguments: [String: Value], schema: Value, step: Int) throws {
        let fields = schema.objectValue?["properties"]?.objectValue ?? [:]
        let required = schema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard Set(arguments.keys).isSubset(of: Set(fields.keys)), required.allSatisfy({ arguments[$0] != nil }) else {
            throw AdaMCPError.invalidArguments("Step \(step) has missing or unknown arguments; see automation.capabilities.commandSchemas.")
        }
        for (key, value) in arguments {
            guard let field = fields[key]?.objectValue else { continue }
            let valid: Bool
            switch field["type"]?.stringValue {
            case "string": valid = value.stringValue?.isEmpty == false
            case "integer": valid = value.intValue != nil
            case "number": valid = value.doubleValue != nil || value.intValue != nil
            case "array": valid = value.arrayValue != nil
            default: valid = true
            }
            guard valid else { throw AdaMCPError.invalidArguments("Step \(step) has invalid type for '\(key)'.") }
            if let options = field["enum"]?.arrayValue, !options.contains(value) {
                throw AdaMCPError.invalidArguments("Step \(step) has invalid value for '\(key)'.")
            }
        }
    }

    private func strictSchema(_ fields: [String: Value], required: [String]) -> Value {
        ["type": "object", "properties": .object(fields), "required": .array(required.map(Value.string)), "additionalProperties": false]
    }
}
