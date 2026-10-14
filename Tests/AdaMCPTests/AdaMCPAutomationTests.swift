import AdaEngine
@testable import AdaMCPCore
import Foundation
import Logging
import MCP
import Testing

@MainActor
@Suite("Automation")
struct AdaMCPAutomationTests {
    struct Position: Component, Codable { var x: Int }
    struct Settings: AdaEngine.Resource, Codable { var name: String }
    struct Signal: Event, Codable { var count: Int }

    private func fixture() -> (AdaMCPRuntime, World, World, Entity) {
        let main = World(name: "Editor")
        let game = World(name: "Game")
        let gameApp = AppWorlds(main: game)
        EventsPlugin().setup(in: gameApp)
        let app = AppWorlds(main: main, subWorlds: ["Game": gameApp])
        let entity = game.spawn("Player") { Position(x: 1) }
        let registry = MCPIntrospectionRegistry()
        registry.registerWritableComponent(Position.self)
        registry.registerWritableResource(Settings.self)
        registry.registerEvent(Signal.self)
        return (AdaMCPRuntime(appWorlds: app, registry: registry,
                             renderCaptureService: RenderCaptureService(appWorlds: app)), main, game, entity)
    }

    @Test func yamlMutatesOnlySelectedWorldAndDeliversTypedEvent() async throws {
        let (runtime, main, game, entity) = fixture()
        let source = """
        - setComponent:
            world: Game
            entity: \(entity.id)
            type: \(String(reflecting: Position.self))
            value: {x: 42}
        - setResource:
            world: Game
            type: \(String(reflecting: Settings.self))
            value: {name: scenario}
        - sendEvent:
            world: Game
            type: \(String(reflecting: Signal.self))
            value: {count: 7}
        """
        let result = await runtime.callTool(name: "automation.run", arguments: ["source": .string(source)])
        try #require(result.isError != true, "\(result)")
        #expect((game.getComponent(named: String(reflecting: Position.self), from: entity.id) as? Position)?.x == 42)
        #expect(game.getResource(Settings.self)?.name == "scenario")
        #expect(main.getResource(Settings.self) == nil)
        let events = Events<Signal>()
        events.update(from: game)
        #expect(events.currentEvents.first?.count == 7)
        let removal = await runtime.callTool(name: "automation.run", arguments: ["steps": [
            ["removeComponent": ["world": "Game", "entity": .int(entity.id), "type": .string(String(reflecting: Position.self))]],
            ["removeResource": ["world": "Game", "type": .string(String(reflecting: Settings.self))]]
        ]])
        #expect(removal.isError != true)
        #expect(game.getComponent(named: String(reflecting: Position.self), from: entity.id) == nil)
        #expect(game.getResource(Settings.self) == nil)
    }

    @Test func transformPayloadUsesQualifiedNameAndCompleteCodableValue() async throws {
        let (runtime, _, game, entity) = fixture()
        runtime.registry.registerWritableComponent(Transform.self)
        let result = await runtime.callTool(name: "automation.run", arguments: ["source": .string("""
        - setComponent:
            world: Game
            entity: \(entity.id)
            type: AdaTransform.Transform
            value:
              position: {x: 10, y: 20, z: 0}
              scale: {x: 1, y: 1, z: 1}
              rotation: {x: 0, y: 0, z: 0, w: 1}
        """)])
        try #require(result.isError != true, "\(result)")
        let transform = try #require(game.getComponent(named: "AdaTransform.Transform", from: entity.id) as? Transform)
        #expect(transform.position == Vector3(10, 20, 0))
        #expect(transform.rotation == .identity)
    }

    @Test func failureReportsStepAndPreservesEarlierCommands() async throws {
        let (runtime, _, game, _) = fixture()
        let type = String(reflecting: Settings.self)
        let result = await runtime.callTool(name: "automation.run", arguments: ["steps": [
            ["setResource": ["world": "Game", "type": .string(type), "value": ["name": "first"]]],
            ["setResource": ["world": "missing", "type": .string(type), "value": ["name": "second"]]],
            ["removeResource": ["world": "Game", "type": .string(type)]]
        ]])
        #expect(result.isError == true)
        let payload = try decode(result)
        #expect(payload["failedStep"]?.intValue == 1)
        #expect(payload["completedSteps"]?.intValue == 1)
        #expect(game.getResource(Settings.self)?.name == "first")
    }

    @Test func malformedDocumentAndMissingWorldAreRejectedBeforeMutation() async throws {
        let (runtime, _, game, _) = fixture()
        let type = String(reflecting: Settings.self)
        for invalid: Value in [
            ["unknown": [:]],
            ["setResource": ["type": .string(type), "value": ["name": "missing world"]]],
            ["wait": [:], "getMetrics": [:]],
            ["tapOn": ["id": "button", "windowId": "wrong type"]],
            ["setResource": ["world": "Game", "type": .string(type), "value": ["name": "value"], "typo": true]]
        ] {
            let result = await runtime.callTool(name: "automation.run", arguments: ["steps": [
                ["setResource": ["world": "Game", "type": .string(type), "value": ["name": "must not run"]]], invalid
            ]])
            #expect(result.isError == true)
            #expect(game.getResource(Settings.self) == nil)
        }
    }

    @Test func readOnlyRegistrationDoesNotGrantWriteAccessAndDecodeFailureDoesNotReplaceResource() async throws {
        let (runtime, _, game, _) = fixture()
        runtime.registry.registerCodable(Transform.self, kind: .component)
        let result = await runtime.callTool(name: "automation.run", arguments: ["steps": [
            ["setResource": ["world": "Game", "type": .string(String(reflecting: Settings.self)), "value": ["name": .int(9)]]]
        ]])
        #expect(result.isError == true)
        #expect(game.getResource(Settings.self) == nil)
        #expect(runtime.automationCapabilities().objectValue?["components"]?.arrayValue?.contains(.string(String(reflecting: Transform.self))) == false)
    }

    @Test func logBufferHasIndependentCursorsAndReportsOverflow() {
        let store = RuntimeLogStore(capacity: 2)
        store.setEnabled(true)
        let logger = Logger(label: "test") { label in
            RuntimeLogHandler(label: label, store: store)
        }
        for index in 1...3 {
            logger.info("log \(index)")
        }
        let first = store.read(after: 0, limit: 1)
        #expect(first.dropped == 1)
        #expect(first.entries.first?.message == "log 2")
        #expect(first.nextCursor == 2)
        #expect(store.read(after: first.nextCursor).entries.first?.message == "log 3")
        #expect(store.read(after: 0).entries.count == 2)
    }

    @Test func logReadWaitsForNewMessagesWithoutConsumingThem() async throws {
        let (runtime, _, _, _) = fixture()
        RuntimeLogStore.shared.setEnabled(true)
        let cursor = RuntimeLogStore.shared.read(after: Int.max).nextCursor
        let read = Task { try await runtime.logsPayload(arguments: ["after": .int(cursor), "waitMs": 1000]) }
        try await Task.sleep(for: .milliseconds(20))
        RuntimeLogStore.shared.append(level: "info", label: "automation-test", message: "new message")
        let result = try await read.value
        #expect(result.objectValue?["entries"]?.arrayValue?.contains { $0.objectValue?["message"]?.stringValue == "new message" } == true)
        #expect(RuntimeLogStore.shared.read(after: cursor).entries.contains { $0.message == "new message" })
    }

    @Test func mutationWaitsForFrameCompletion() async throws {
        let (runtime, _, game, _) = fixture()
        let gate = AutomationFrameGate()
        runtime.appWorlds.main.insertResource(AutomationGateResource(gate: gate))
        runtime.appWorlds.updateScheduler = .update
        runtime.appWorlds.main.addSchedulers(.update)
        runtime.appWorlds.getSubworldBuilder(by: AppWorldName(rawValue: "Game"))?.updateScheduler = .update
        game.addSchedulers(.update)
        runtime.appWorlds.addSystem(AutomationBlockingSystem.self)
        try await runtime.appWorlds.build()
        let frame = Task { try await runtime.appWorlds.update() }
        await gate.waitUntilEntered()
        let mutation = Task {
            await runtime.callTool(name: "automation.run", arguments: ["steps": [
                ["setResource": ["world": "Game", "type": .string(String(reflecting: Settings.self)), "value": ["name": "after frame"]]]
            ]])
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(game.getResource(Settings.self) == nil)
        await gate.release()
        try await frame.value
        let result = await mutation.value
        #expect(result.isError != true)
        #expect(game.getResource(Settings.self)?.name == "after frame")
    }

    private func decode(_ result: CallTool.Result) throws -> [String: Value] {
        guard case .text(let text, _, _) = result.content.first else {
            throw AdaMCPError.invalidArguments("Expected text result")
        }
        return try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
    }
}

actor AutomationFrameGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

struct AutomationGateResource: AdaEngine.Resource {
    let gate: AutomationFrameGate
}

@PlainSystem
struct AutomationBlockingSystem {
    @Res<AutomationGateResource> private var gate

    init(world: World) { }

    func update(context: UpdateContext) async {
        await gate.gate.hold()
    }
}
