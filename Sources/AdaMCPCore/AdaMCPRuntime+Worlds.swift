import AdaEngine
import MCP

extension AdaMCPRuntime {
    func listWorldsPayload() throws -> Value {
        let worlds = try appWorlds.allWorldNames().map { worldName -> Value in
            guard let worldBuilder = appWorlds.getWorldBuilder(by: worldName) else {
                throw AdaMCPError.worldNotFound(worldName.rawValue)
            }
            return self.makeWorldPayload(worldName: worldName.rawValue, world: worldBuilder.main)
        }
        return ["worlds": .array(worlds)]
    }

    func worldPayload(named worldName: String?) throws -> Value {
        let resolved = try self.resolveWorld(named: worldName)
        return self.makeWorldPayload(worldName: resolved.name, world: resolved.world.main)
    }

    func typeListPayload(kind: String) throws -> Value {
        let typeKind: MCPTypeKind
        switch kind {
        case "components":
            typeKind = .component
        case "resources":
            typeKind = .resource
        case "assets":
            typeKind = .asset
        default:
            throw AdaMCPError.invalidResourceURI("ada://types/\(kind)")
        }
        return try Value(registry.descriptors(kind: typeKind))
    }

    func resolveWorld(named name: String?) throws -> (name: String, world: AppWorlds) {
        let worldName = name?.isEmpty == false ? name! : AppWorldName.main.rawValue
        guard let world = appWorlds.getWorldBuilder(by: AppWorldName(rawValue: worldName)) else {
            throw AdaMCPError.worldNotFound(worldName)
        }
        return (worldName, world)
    }
}

private extension AdaMCPRuntime {
    func makeWorldPayload(worldName: String, world: World) -> Value {
        let entities = world.getEntities()
        return .object([
            "type": "world",
            "name": .string(worldName),
            "world": .string(worldName),
            "summary": .object([
                "entityCount": .int(entities.count),
                "activeEntityCount": .int(entities.filter(\.isActive).count),
                "resourceCount": .int(world.getResources().count)
            ]),
            "fields": .object([
                "id": .string(String(describing: world.id)),
                "name": .string(world.name ?? worldName)
            ]),
            "diagnostics": .array([])
        ])
    }
}
