import MCP

extension AdaMCPRuntime {
    func listResourcesPayload(arguments: [String: Value]) throws -> Value {
        let resolved = try self.resolveWorld(named: arguments["world"]?.stringValue)
        var payloads: [Value] = []
        var diagnostics: [Value] = []

        for resource in resolved.world.main.getResources() {
            do {
                payloads.append(try self.inspectValue(resource))
            } catch {
                diagnostics.append(self.diagnosticValue(
                    code: "not_inspectable",
                    message: "Resource \(String(reflecting: type(of: resource))) is not inspectable."
                ))
            }
        }

        return ["resources": .array(payloads), "diagnostics": .array(diagnostics)]
    }

    func resourcePayload(arguments: [String: Value]) throws -> Value {
        guard let resourceType = arguments["resourceType"]?.stringValue, !resourceType.isEmpty else {
            throw AdaMCPError.invalidArguments("Argument 'resourceType' is required.")
        }
        let resolved = try self.resolveWorld(named: arguments["world"]?.stringValue)
        guard let resource = resolved.world.main.getResource(named: resourceType) else {
            throw AdaMCPError.resourceNotFound(resourceType)
        }
        return try self.inspectValue(resource)
    }

    func inspectValue(_ value: Any) throws -> Value {
        guard let descriptor = registry.descriptor(for: value) else {
            throw AdaMCPError.notInspectable(String(reflecting: type(of: value)))
        }
        guard let serialized = try registry.serialize(value) else {
            throw AdaMCPError.notInspectable(descriptor.name)
        }
        let fields = serialized.objectValue ?? ["value": serialized]
        return .object([
            "type": .string(descriptor.name),
            "kind": .string(descriptor.kind.rawValue),
            "summary": .object([
                "fieldCount": .int(fields.count)
            ]),
            "fields": .object(fields),
            "diagnostics": .array([])
        ])
    }

    func diagnosticValue(code: String, message: String) -> Value {
        .object([
            "code": .string(code),
            "message": .string(message)
        ])
    }
}
