import AdaEngine
import MCP

extension AdaMCPRuntime {
    func mutationPayload(command: String, arguments: [String: Value]) async throws -> Value {
        try await appWorlds.withWorldAccess {
            let worldName = try requiredString(arguments, "world")
            let world = try resolveWorld(named: worldName).world.main
            let type = try requiredString(arguments, "type")
            switch command {
            case "setComponent", "removeComponent":
                guard let entity = arguments["entity"]?.intValue else {
                    throw AdaMCPError.invalidArguments("Integer 'entity' is required.")
                }
                guard world.getEntityByID(entity) != nil else {
                    throw AdaMCPError.entityNotFound(world: worldName, entityID: entity)
                }
                if command == "setComponent" {
                    guard let writer = registry.componentWriters[type] else { throw unavailable(type) }
                    try writer(world, entity, requiredValue(arguments))
                } else {
                    guard let remover = registry.componentRemovers[type] else { throw unavailable(type) }
                    remover(world, entity)
                }
            case "setResource":
                guard let writer = registry.resourceWriters[type] else { throw unavailable(type) }
                try writer(world, requiredValue(arguments))
            case "removeResource":
                guard let remover = registry.resourceRemovers[type] else { throw unavailable(type) }
                remover(world)
            case "sendEvent":
                guard let sender = registry.eventSenders[type] else { throw unavailable(type) }
                try sender(world, requiredValue(arguments))
            default:
                throw AdaMCPError.invalidArguments("Unknown mutation '\(command)'.")
            }
            return ["world": .string(worldName), "type": .string(type), "command": .string(command)]
        }
    }

    func requiredString(_ arguments: [String: Value], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AdaMCPError.invalidArguments("Non-empty '\(key)' is required.")
        }
        return value
    }

    private func requiredValue(_ arguments: [String: Value]) throws -> Value {
        guard let value = arguments["value"] else { throw AdaMCPError.invalidArguments("'value' is required.") }
        return value
    }

    private func unavailable(_ type: String) -> AdaMCPError {
        .invalidArguments("Type '\(type)' is not registered for this operation. See automation.capabilities.")
    }
}
