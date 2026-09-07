import AdaEngine
import Foundation
import MCP

public extension MCPIntrospectionRegistry {
    /// Opts a component into complete-value replacement and removal through automation.
    /// The file identifier is the qualified Swift type name (String(reflecting:)).
    func registerWritableComponent<T: Component & Codable>(_ type: T.Type) {
        type.registerComponent()
        registerCodable(type, kind: .component)
        let name = String(reflecting: type)
        componentWriters[name] = { world, entity, value in
            let component = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
            world.insert(component, for: entity)
        }
        componentRemovers[name] = { world, entity in world.remove(T.self, from: entity) }
    }

    /// Opts a resource into complete-value replacement and removal through automation.
    func registerWritableResource<T: AdaEngine.Resource & Codable>(_ type: T.Type) {
        type.registerResource()
        registerCodable(type, kind: .resource)
        let name = String(reflecting: type)
        resourceWriters[name] = { world, value in
            world.insertResource(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)))
        }
        resourceRemovers[name] = { world in world.removeResource(T.self) }
    }

    /// Registers a typed ECS event delivered through the world's normal Events<T> storage.
    func registerEvent<T: Event & Codable>(_ type: T.Type) {
        eventSenders[String(reflecting: type)] = { world, value in
            guard world.supportsEventDelivery else {
                throw AdaMCPError.invalidArguments("World has no event lifecycle. Install EventsPlugin before sending events.")
            }
            let event = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
            let sender = EventsSender<T>()
            sender.update(from: world)
            sender.send(event)
        }
    }
}
