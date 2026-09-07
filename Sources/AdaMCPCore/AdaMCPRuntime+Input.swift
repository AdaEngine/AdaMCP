@_spi(Internal) import AdaEngine
import Foundation
import MCP

extension AdaMCPRuntime {
    func inputEventPayload(command: String, arguments: [String: Value]) async throws -> Value {
        try await appWorlds.withWorldAccess {
            let worldName = try requiredString(arguments, "world")
            let world = try resolveWorld(named: worldName).world.main
            guard world.getResource(Input.self) != nil else {
                throw AdaMCPError.invalidArguments("World '\(worldName)' has no Input resource. Install InputPlugin.")
            }
            guard let windowID = arguments["windowId"]?.intValue else {
                throw AdaMCPError.invalidArguments("'windowId' is required for input events.")
            }
            let window = try uiInspectionService.resolveWindow(windowID: windowID).id
            let time = Float(Date().timeIntervalSinceReferenceDate)
            let input = world.getRefResource(Input.self)
            if command == "keyEvent" {
                let key = try requiredString(arguments, "key")
                guard let keyCode = KeyCode.allCases.first(where: { String(describing: $0) == key || $0.rawValue == key }),
                      let status = ["down": KeyEvent.Status.down, "up": .up][try requiredString(arguments, "status")] else {
                    throw AdaMCPError.invalidArguments("Unknown key or status (down/up).")
                }
                input.wrappedValue.receiveEvent(KeyEvent(window: window, keyCode: keyCode, modifiers: try inputModifiers(arguments),
                                                         status: status, time: time, isRepeated: false))
            } else {
                let point = Point(try inputNumber(arguments, "x"), try inputNumber(arguments, "y"))
                if command == "pinchEvent" {
                    let scale = try inputNumber(arguments, "scale")
                    guard scale > 0, let phase = PinchEvent.Phase(rawValue: try requiredString(arguments, "phase")) else {
                        throw AdaMCPError.invalidArguments("Pinch requires scale > 0 and phase began/changed/ended/cancelled.")
                    }
                    input.wrappedValue.receiveEvent(PinchEvent(window: window, location: point, scale: scale, phase: phase, time: time))
                } else {
                    let phases: [MouseEvent.Phase]
                    if command == "tapEvent" {
                        phases = [.began, .ended]
                    } else {
                        guard let phase = ["began": MouseEvent.Phase.began, "changed": .changed, "ended": .ended,
                                           "cancelled": .cancelled][try requiredString(arguments, "phase")] else {
                            throw AdaMCPError.invalidArguments("Mouse phase must be began/changed/ended/cancelled.")
                        }
                        phases = [phase]
                    }
                    let buttonName = arguments["button"]?.stringValue ?? "left"
                    guard let button = ["left": MouseButton.left, "right": .right, "middle": .middle, "none": .none][buttonName] else {
                        throw AdaMCPError.invalidArguments("Unknown mouse button '\(buttonName)'.")
                    }
                    let scroll = command == "scrollEvent"
                        ? Point(try inputNumber(arguments, "deltaX"), try inputNumber(arguments, "deltaY")) : .zero
                    let modifiers = try inputModifiers(arguments)
                    for phase in phases {
                        input.wrappedValue.receiveEvent(MouseEvent(window: window, button: command == "scrollEvent" ? .scrollWheel : button,
                            scrollDelta: scroll, mousePosition: point, phase: phase, modifierKeys: modifiers, time: time))
                    }
                }
            }
            return ["world": .string(worldName), "windowId": .int(windowID), "command": .string(command), "status": "queued"]
        }
    }

    private func inputNumber(_ arguments: [String: Value], _ key: String) throws -> Float {
        guard let value = arguments[key]?.doubleValue ?? arguments[key]?.intValue.map(Double.init),
              value.isFinite, Float(value).isFinite else {
            throw AdaMCPError.invalidArguments("Finite number '\(key)' is required.")
        }
        return Float(value)
    }

    private func inputModifiers(_ arguments: [String: Value]) throws -> KeyModifier {
        guard let value = arguments["modifiers"] else { return [] }
        guard let values = value.arrayValue else { throw AdaMCPError.invalidArguments("'modifiers' must be an array.") }
        var result: KeyModifier = []
        for value in values {
            guard let name = value.stringValue,
                  let modifier = ["shift": KeyModifier.shift, "control": .control, "alt": .alt, "main": .main, "capsLock": .capsLock][name] else {
                throw AdaMCPError.invalidArguments("Unknown key modifier.")
            }
            result.formUnion(modifier)
        }
        return result
    }
}
