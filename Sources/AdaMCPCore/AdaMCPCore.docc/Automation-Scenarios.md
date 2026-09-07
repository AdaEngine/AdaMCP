# Automation scenarios

Run an ordered YAML or JSON file against a live AdaEngine application. The syntax follows
[Maestro's command-list style](https://docs.maestro.dev/maestro-flows), with ECS operations in addition to UI commands.
It is an AdaMCP format, not a compatible implementation of the Maestro command library.

## From an agent

1. Connect using the `adamcp` router. Select the intended application with `adamcp.list_servers` / `adamcp.select_server` when several are running.
2. Call `world.list_worlds`, `entity.find`, `ui.list_windows`, `ui.get_tree`, and `automation.capabilities` to discover current targets and writable types. Capabilities include `commandSchemas` with required arguments and JSON types.
3. Write a UTF-8 `.yaml` or `.json` file and call `adamcp.run_file` with `{"path":"/absolute/path/scenario.yaml"}`.
   The **router host** reads the file and sends its content to the selected application, so the application does not need filesystem access to that path.
4. Direct HTTP/stdio clients can call `automation.run` with `{"source":"<file contents>"}` or `{"steps":[...]}` instead.

The document is one YAML sequence (or JSON array). It has no Maestro appId header, variable interpolation, scripts, or nested flows.
Use spaces for YAML indentation. Each step is one command with an object payload; empty payloads use `{}`.
A document accepts at most 1000 steps, and source files are limited to 1 MiB.

```yaml
- setComponent:
    world: SceneView.REPLACE_WITH_LIVE_ID
    entity: 123
    type: AdaTransform.Transform
    value:
      position: {x: 10, y: 20, z: 0}
      scale: {x: 1, y: 1, z: 1}
      rotation: {x: 0, y: 0, z: 0, w: 1}
- tapOn:
    windowId: 456
    id: game.start
- wait:
    milliseconds: 100
- getMetrics: {}
- getLogs:
    after: 0
    limit: 100
```

## Worlds and writable types

All component, resource and raw input/event commands require an explicit `world`. There is no default world for mutation.
`Main` is the application's main world. Editor scene viewports are hosted as `SceneView.<UUID>` subworlds;
resolve them anew with `world.list_worlds` and inspect entities to identify the intended scene.
Runtime world/entity IDs are session-local and should not be stored as persistent scene identifiers.
ECS changes affect the live world; they do not edit or save an Editor `.ascn` document.

`type` is the qualified Swift name returned by `automation.capabilities`, not an unstable component runtime ID.
`value` is a **complete Codable payload**, replacing the component/resource, not a partial field patch.
Use `component.get` / `resource.get` and their `fields` payload to inspect the serialization shape.
Unknown, unregistered or undecodable types fail before that step changes storage.
Removal is idempotent for missing values on an existing entity/world.

MCPPlugin registers `AdaTransform.Transform` and `AdaApp.SimulationControl` as writable built-ins.
Other types must opt into mutation when configuring the plugin:

```swift
MCPPlugin(configuration: .init(registerTypes: { registry in
    registry.registerWritableComponent(Health.self) // Component & Codable
    registry.registerWritableResource(GameSettings.self) // Resource & Codable
    registry.registerEvent(SpawnEnemy.self) // Event & Codable
}))
```

`registerCodable` alone remains read-only. The existing read-only type registration API is unchanged.
Custom events use the normal `Events<T>` lifecycle and require `EventsPlugin` in the target world.

```yaml
- setResource:
    world: Main
    type: MyGame.GameSettings
    value: {difficulty: 2}
- sendEvent:
    world: Main
    type: MyGame.SpawnEnemy
    value: {count: 3}
- removeComponent:
    world: Main
    entity: 123
    type: MyGame.Health
- removeResource:
    world: Main
    type: MyGame.GameSettings
```

## UI and input

AdaUI already supports `.accessibilityIdentifier("game.start")`. `tapOn`, `scrollTo`, and `focusOn` use
`id` to match that identifier, plus an optional `windowId`. Duplicate matches are errors, not arbitrary picks.
`tapOn` uses AdaUI's hit-testing and normal mouse began/ended delivery; `scrollTo` scrolls the nearest ancestor container.
Scroll an offscreen target into view before tapping it. A returned tap result describes delivery, not application-specific state assertions.

Raw events require `world`, `windowId`, and an installed `InputPlugin` in that world.
They are queued exactly like platform events and consumed on the next update of that world.
A queued response is not a promise that a UI or gameplay callback has already completed.
Use `wait` for running worlds or `stepFrame` for deterministic advancement.

| Command | Additional fields |
| --- | --- |
| `tapEvent` | `x`, `y`, optional `button` (left/right/middle/none); queues began + ended |
| `mouseEvent` | `x`, `y`, `phase` (began/changed/ended/cancelled), optional `button` |
| `scrollEvent` | `x`, `y`, `deltaX`, `deltaY`, `phase`; uses scrollWheel |
| `keyEvent` | `key` (Swift case name or raw character), `status` (down/up) |
| `pinchEvent` | `x`, `y`, `scale` (>0, relative to gesture start), `phase` |

Mouse/key events accept `modifiers: [shift, control, alt, main, capsLock]`.
Positions use the input coordinate system of the selected world (window coordinates for main UI; viewport-local coordinates for scene input).
`PinchEvent` is available to gameplay through `Input.getInputEvents()`; it does not install an AdaUI magnification recognizer.

```yaml
- keyEvent:
    world: Main
    windowId: 456
    key: space
    status: down
- stepFrame:
    frames: 1
- keyEvent:
    world: Main
    windowId: 456
    key: space
    status: up
- stepFrame:
    frames: 1
```

`stepFrame` advances the app through the existing runtime stepping API and leaves main simulation paused.
Call `runtime.resume` afterward when continuous simulation should continue. `wait` accepts 0–30000 milliseconds;
`stepFrame` accepts 1–120 frames.

## Logs and metrics

`profiler.live_snapshot` remains the live metrics endpoint; `getMetrics: {}` records a snapshot in the scenario report.
`logs.read` (or the `getLogs` step) returns `{entries,nextCursor,dropped}`. Call again with `after: nextCursor` and
`waitMs: 30000` to follow new logs without blocking the engine. Independent readers do not consume each other's entries.
The buffer holds 2048 messages with bounded text; `dropped` reports messages lost since the requested cursor.
These are process logs, not per-world logs. `print`, OS logs, and child-process stderr are not captured.

MCPPlugin enables capture. Normal AdaEngine App startup multiplexes swift-log into the diagnostic store and the console.
A custom embedding host that bootstraps swift-log itself must include `RuntimeLogHandler(label:)` in its logging factory.

## Execution contract

The runtime validates command names, document structure and explicit world arguments before starting. Payload decoding and
live-target resolution happen at each step. Synchronous ECS mutations wait for the current root AppWorlds update to finish,
including subworld scheduling and extraction, then run without suspension. Only one scenario runs per AdaMCPRuntime at a time.

The result contains `status`, `completedSteps` and per-step `results`. Failure sets MCP `isError: true` and includes the
zero-based `failedStep`, `command`, message, and any structured AdaMCP error. Earlier successful steps remain applied;
there is no rollback and no automatic retry of side effects. Cancellation is checked between commands and at asynchronous waits.
