import AdaEngine
import MCP

extension AdaMCPRuntime {
    func entityByIDPayload(arguments: [String: Value]) throws -> Value {
        guard let entityID = arguments["id"]?.intValue else {
            throw AdaMCPError.invalidArguments("Argument 'id' is required.")
        }
        let worldName = arguments["world"]?.stringValue ?? AppWorldName.main.rawValue
        return try self.entityPayload(worldName: worldName, entityID: entityID)
    }

    func entityByNamePayload(arguments: [String: Value]) throws -> Value {
        guard let entityName = arguments["name"]?.stringValue, !entityName.isEmpty else {
            throw AdaMCPError.invalidArguments("Argument 'name' is required.")
        }
        let resolved = try self.resolveWorld(named: arguments["world"]?.stringValue)
        guard let entity = resolved.world.main.getEntityByName(entityName) else {
            throw AdaMCPError.entityNamedNotFound(world: resolved.name, entityName: entityName)
        }
        return try self.makeEntityPayload(worldName: resolved.name, world: resolved.world.main, entity: entity)
    }

    func findEntitiesPayload(arguments: [String: Value]) throws -> Value {
        let resolved = try self.resolveWorld(named: arguments["world"]?.stringValue)
        let nameQuery = arguments["name"]?.stringValue?.lowercased()
        let active = arguments["active"]?.boolValue
        let componentType = arguments["componentType"]?.stringValue

        let entities = try resolved.world.main.getEntities().filter { entity in
            if let nameQuery, !entity.name.lowercased().contains(nameQuery) {
                return false
            }
            if let active, entity.isActive != active {
                return false
            }
            if let componentType, !resolved.world.main.hasComponent(named: componentType, in: entity.id) {
                return false
            }
            return true
        }
        .map { entity in
            try self.makeEntityPayload(worldName: resolved.name, world: resolved.world.main, entity: entity)
        }

        return ["entities": .array(entities)]
    }

    func entityComponentsPayload(arguments: [String: Value]) throws -> Value {
        guard let entityID = arguments["entityId"]?.intValue else {
            throw AdaMCPError.invalidArguments("Argument 'entityId' is required.")
        }
        let resolved = try self.resolveWorld(named: arguments["world"]?.stringValue)
        guard let entity = resolved.world.main.getEntityByID(entityID) else {
            throw AdaMCPError.entityNotFound(world: resolved.name, entityID: entityID)
        }
        let components = try self.inspectComponents(world: resolved.world.main, entity: entity)
        return ["components": .array(components.payloads), "diagnostics": .array(components.diagnostics)]
    }

    func componentPayload(arguments: [String: Value]) throws -> Value {
        guard let entityID = arguments["entityId"]?.intValue else {
            throw AdaMCPError.invalidArguments("Argument 'entityId' is required.")
        }
        guard let componentType = arguments["componentType"]?.stringValue, !componentType.isEmpty else {
            throw AdaMCPError.invalidArguments("Argument 'componentType' is required.")
        }
        let resolved = try self.resolveWorld(named: arguments["world"]?.stringValue)
        guard resolved.world.main.getEntityByID(entityID) != nil else {
            throw AdaMCPError.entityNotFound(world: resolved.name, entityID: entityID)
        }
        guard let component = resolved.world.main.getComponent(named: componentType, from: entityID) else {
            throw AdaMCPError.componentNotFound(
                world: resolved.name,
                entityID: entityID,
                componentType: componentType
            )
        }
        return try self.inspectValue(component)
    }

    func entityPayload(worldName: String, entityID: Int) throws -> Value {
        let resolved = try self.resolveWorld(named: worldName)
        guard let entity = resolved.world.main.getEntityByID(entityID) else {
            throw AdaMCPError.entityNotFound(world: resolved.name, entityID: entityID)
        }
        return try self.makeEntityPayload(worldName: resolved.name, world: resolved.world.main, entity: entity)
    }
}

private extension AdaMCPRuntime {
    func makeEntityPayload(worldName: String, world: World, entity: Entity) throws -> Value {
        let components = try self.inspectComponents(world: world, entity: entity)
        return .object([
            "type": "entity",
            "id": .int(entity.id),
            "name": .string(entity.name),
            "world": .string(worldName),
            "summary": .object([
                "isActive": .bool(entity.isActive),
                "componentCount": .int(entity.components.count),
                "inspectableComponentCount": .int(components.payloads.count)
            ]),
            "fields": .object([
                "isActive": .bool(entity.isActive)
            ]),
            "components": .array(components.payloads),
            "diagnostics": .array(components.diagnostics)
        ])
    }

    func inspectComponents(
        world: World,
        entity: Entity
    ) throws -> (payloads: [Value], diagnostics: [Value]) {
        var payloads: [Value] = []
        var diagnostics: [Value] = []

        for (typeName, component) in world.getComponents(for: entity.id) {
            do {
                payloads.append(try self.inspectValue(component))
            } catch {
                diagnostics.append(self.diagnosticValue(
                    code: "not_inspectable",
                    message: "Component \(typeName) on entity \(entity.id) is not inspectable."
                ))
            }
        }

        return (payloads, diagnostics)
    }
}
