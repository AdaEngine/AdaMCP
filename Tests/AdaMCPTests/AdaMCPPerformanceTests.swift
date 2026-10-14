import AdaApp
import AdaECS
@testable import AdaMCPCore
import AdaUtils
import Foundation
import InMemoryTracing
import MCP
import Testing
import Tracing

@MainActor
@Suite(.serialized)
struct AdaMCPPerformanceTests {
    struct Instant: TracerInstant {
        let nanosecondsSinceEpoch: UInt64
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanosecondsSinceEpoch < rhs.nanosecondsSinceEpoch }
    }

    private func emit(_ tracer: AdaMCPTracer, target: String?, name: String = "AppWorlds.update", root: Bool = true,
                      start: UInt64, duration: UInt64 = 1_000_000, context: ServiceContext = .topLevel) {
        AdaTrace.$profileTargetID.withValue(target) {
            AdaTrace.$profileFrameRoot.withValue(root) {
                let span = tracer.startSpan(name, context: context, at: Instant(nanosecondsSinceEpoch: start))
                span.attributes["ada.profile.entities"] = 42
                span.end(at: Instant(nanosecondsSinceEpoch: start + duration))
            }
        }
    }

    @Test func isolatesTargetsAndCountsNestedFramesBeforeRingEviction() throws {
        let recorder = AdaMCPTraceRecorder(tracer: AdaMCPTracer(maxFinishedSpanCount: 2, continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let first = profiler.performance.register(title: "First")
        let second = profiler.performance.register(title: "Second")
        let lease = try profiler.performance.subscribe(targetID: first)
        let secondLease = try profiler.performance.subscribe(targetID: second)
        let parent = recorder.tracer.startSpan("Editor")
        for index in 0..<120 {
            let start = 1_000_000_000 + UInt64(index) * 16_666_667
            emit(recorder.tracer, target: first, start: start, context: parent.context)
            emit(recorder.tracer, target: first, root: false, start: start)
            emit(recorder.tracer, target: second, start: start, duration: 4_000_000)
            emit(recorder.tracer, target: nil, start: start, duration: 20_000_000)
        }
        parent.end()
        profiler.performance.sample()
        let firstSample = try #require(profiler.performance.target(first)?.samples.last)
        let secondSample = try #require(profiler.performance.target(second)?.samples.last)
        #expect(firstSample.update?.count == 120)
        #expect(firstSample.update?.meanMs == 1)
        #expect(abs((firstSample.updatesPerSecond ?? 0) - 60) < 0.01)
        #expect(secondSample.update?.meanMs == 4)
        #expect(firstSample.entityCount == 42)
        #expect(recorder.tracer.droppedSpanCount > 400)
        withExtendedLifetime((lease, secondLease)) {}
    }

    @Test func subscriptionsDoNotDisableEachOtherAndResumeWithoutGapRate() throws {
        let recorder = AdaMCPTraceRecorder(tracer: AdaMCPTracer(continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let id = profiler.performance.register(title: "Game")
        var panel: AdaMCPTraceLease? = try profiler.performance.subscribe(targetID: id)
        var second: AdaMCPTraceLease? = try profiler.performance.subscribe(targetID: id)
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        panel = nil
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        emit(recorder.tracer, target: id, start: 1_000_000_000)
        profiler.performance.sample()
        second = nil
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
        panel = try profiler.performance.subscribe(targetID: id)
        emit(recorder.tracer, target: id, start: 100_000_000_000)
        profiler.performance.sample()
        #expect(profiler.performance.target(id)?.samples.last?.updatesPerSecond == nil)
        withExtendedLifetime((panel, second)) {}
    }

    @Test func sharedSnapshotAndStoppedRunRemainAvailable() throws {
        let recorder = AdaMCPTraceRecorder()
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let id = profiler.performance.register(title: "Game")
        let lease = try profiler.performance.subscribe(targetID: id)
        emit(recorder.tracer, target: id, start: 1_000_000_000)
        profiler.performance.sample()
        let payload = try profiler.liveSnapshotPayload(targetID: id)
        let decoded = try JSONDecoder().decode(AdaMCPPerformanceTarget.self, from: JSONEncoder().encode(payload))
        #expect(decoded == profiler.performance.target(id))
        try profiler.stopTarget(id)
        #expect(profiler.performance.target(id)?.isRunning == false)
        #expect(profiler.performance.target(id)?.samples.count == 1)
        let next = profiler.performance.register(title: "Game")
        #expect(next != id)
        #expect(profiler.performance.target(next)?.samples.isEmpty == true)
        withExtendedLifetime(lease) {}
    }

    @Test func scopedCaptureSurvivesRingOverflowAndExportsOnlyGame() throws {
        let recorder = AdaMCPTraceRecorder(tracer: AdaMCPTracer(maxFinishedSpanCount: 1, continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let id = profiler.performance.register(title: "Game")
        let result = try profiler.startCapture(arguments: ["targetId": .string(id), "frameCount": .int(3)])
        let captureID = try #require(result.objectValue?["id"]?.stringValue)
        let start = DefaultTracerClock.now.nanosecondsSinceEpoch
        let parent = recorder.tracer.startSpan("Editor")
        for index in 0..<3 {
            emit(recorder.tracer, target: id, start: start + UInt64(index) * 16_000_000, context: parent.context)
            emit(recorder.tracer, target: nil, name: "System.execute.Editor", start: start)
        }
        parent.end()
        let capture = try profiler.capturePayload(id: captureID).objectValue
        #expect(capture?["manifest"]?.objectValue?["state"]?.stringValue == "completed")
        #expect(capture?["manifest"]?.objectValue?["targetId"]?.stringValue == id)
        #expect(capture?["summary"]?.objectValue?["frameCount"]?.intValue == 3)
        #expect(capture?["spans"]?.arrayValue?.count == 3)
        #expect(capture?["trace"]?.objectValue?["traceEvents"]?.arrayValue?.count == 3)
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
    }

    @Test func stoppingGameCompletesCaptureAndRejectsAnotherCapture() throws {
        let recorder = AdaMCPTraceRecorder()
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let id = profiler.performance.register(title: "Game")
        _ = try profiler.startCapture(arguments: ["targetId": .string(id), "durationMs": .int(5000)])
        #expect(throws: (any Error).self) { try profiler.startCapture(arguments: [:]) }
        try profiler.stopTarget(id)
        let manifest = try #require(profiler.capturePayload(id: nil).objectValue?["manifest"]?.objectValue)
        #expect(manifest["state"]?.stringValue == "completed")
        #expect((manifest["durationMs"]?.doubleValue ?? 5000) < 5000)
    }

    @Test func realAppWorldContextSeparatesGameAndRenderFrames() async throws {
        let recorder = AdaMCPTraceRecorder.activeGlobalRecorder() ?? AdaMCPTraceRecorder()
        try #require(recorder.installAsGlobalTracerIfPossible())
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let id = profiler.performance.register(title: "Real Game")
        let render = AppWorlds(main: World(name: "Render"))
        render.updateScheduler = .update
        let game = AppWorlds(main: World(name: "SceneView"), subWorlds: ["Render": render])
        game.profilingTargetID = id
        game.updateScheduler = .update
        try await game.build()
        let lease = try profiler.performance.subscribe(targetID: id)
        try await game.update()
        profiler.performance.sample()
        #expect(profiler.performance.target(id)?.samples.last?.update?.count == 1)
        let spans = recorder.tracer.finishedSpans.filter { $0.operationName == "AppWorlds.update" }
        #expect(spans.contains { $0.attributes["ada.profile.target_id"]?.toSpanAttribute() == .string(id) && $0.attributes["ada.profile.frame_root"]?.toSpanAttribute() == .bool(false) })
        withExtendedLifetime(lease) {}
    }
}
