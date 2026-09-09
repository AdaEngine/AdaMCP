import AdaMCPCore
import AdaUtils
import Foundation
import Testing
import Tracing

@Suite(.serialized)
struct AdaTracePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_PERFORMANCE_BENCHMARK"] == "1"))
    func measureEngineSystemSpans() async throws {
        let recorder = AdaMCPTraceRecorder.activeGlobalRecorder() ?? AdaMCPTraceRecorder()
        #expect(recorder.installAsGlobalTracerIfPossible())
        let wasContinuous = recorder.tracer.isContinuousRecordingEnabled
        recorder.tracer.setContinuousRecordingEnabled(true)
        defer { recorder.tracer.setContinuousRecordingEnabled(wasContinuous) }
        // Real ECS system spans inherit a frame/scheduler context instead of
        // generating a new root trace ID for each system invocation.
        await Tracing.withSpan("Benchmark.frame") { _ async in
            let clock = ContinuousClock()
            var referenceTimes: [Duration] = []
            var activeTimes: [Duration] = []
            var idleTimes: [Duration] = []
            for _ in 0..<5 {
                recorder.tracer.setContinuousRecordingEnabled(true)
                let referenceStart = clock.now
                for index in 0..<30_000 {
                    await Tracing.withSpan("System.execute.Test\(index % 8)") { span async in
                        span.attributes["ada.profile.category"] = "system"
                        span.attributes["ada.scheduler.name"] = "Update"
                        span.attributes["ada.system.name"] = "Test"
                        span.attributes["ada.world.name"] = "Main"
                    }
                }
                referenceTimes.append(referenceStart.duration(to: clock.now))
                let activeStart = clock.now
                for index in 0..<30_000 {
                    await AdaTrace.span(lazyName: "System.execute.Test\(index % 8)", attributes: [
                        "ada.profile.category": "system", "ada.scheduler.name": "Update",
                        "ada.system.name": "Test", "ada.world.name": "Main"
                    ]) { () async in }
                }
                activeTimes.append(activeStart.duration(to: clock.now))
                recorder.tracer.setContinuousRecordingEnabled(false)
                let idleStart = clock.now
                for index in 0..<30_000 {
                    await AdaTrace.span(lazyName: "System.execute.Test\(index % 8)", attributes: [
                        "ada.profile.category": "system", "ada.scheduler.name": "Update",
                        "ada.system.name": "Test", "ada.world.name": "Main"
                    ]) { () async in }
                }
                idleTimes.append(idleStart.duration(to: clock.now))
            }
            print("PERFORMANCE 30000 async nested spans; median of 5")
            print("PERFORMANCE reference individual attributes: \(referenceTimes.sorted()[2]); runs: \(referenceTimes)")
            print("PERFORMANCE active batched attributes: \(activeTimes.sorted()[2]); runs: \(activeTimes)")
            print("PERFORMANCE idle fast path: \(idleTimes.sorted()[2]); runs: \(idleTimes)")
        }
        #expect(recorder.finishedSpanCount == 1_000)
    }
}
