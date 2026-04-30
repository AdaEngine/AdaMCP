import AdaEngine
import MCP

extension AdaMCPRuntime {
    func pausePayload(reason: String?) throws -> Value {
        let control = appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        control.wrappedValue.mode = .paused
        control.wrappedValue.reason = reason ?? "runtime.pause"
        control.wrappedValue.pendingStepCount = 0
        return try Value(control.wrappedValue)
    }

    func resumePayload() throws -> Value {
        let control = appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        control.wrappedValue.mode = .running
        control.wrappedValue.reason = nil
        control.wrappedValue.pendingStepCount = 0
        return try Value(control.wrappedValue)
    }

    func stepFramePayload(frames: Int) async throws -> Value {
        let frameCount = max(frames, 1)
        let control = appWorlds.main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        control.wrappedValue.mode = .paused
        control.wrappedValue.reason = "runtime.step_frame"
        control.wrappedValue.pendingStepCount += frameCount

        for _ in 0..<frameCount {
            try await appWorlds.update()
        }

        return try Value(control.wrappedValue)
    }
}
