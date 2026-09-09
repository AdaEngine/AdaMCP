import AdaApp
import AdaECS
import AdaMCPCore
@testable import AdaUtils
import Foundation
import InMemoryTracing
import MCP
import Synchronization
import Testing
import Tracing

@MainActor
@Suite(.serialized)
struct AdaTraceControlTests {
    @Test
    func batchedAttributesPreserveProviderDefaults() {
        let tracer = AdaMCPTracer()
        let span = tracer.startSpan("provider-defaults")
        span.attributes["provider"] = "retained"
        span.attributes["overridden"] = "old"
        AdaTrace.mergeAttributes(["overridden": "new", "operation": "value"], into: span)
        AdaTrace.mergeAttributes([:], into: span)
        span.end()
        let attributes = tracer.finishedSpans.first?.attributes
        #expect(attributes?["provider"]?.toSpanAttribute() == .string("retained"))
        #expect(attributes?["overridden"]?.toSpanAttribute() == .string("new"))
        #expect(attributes?["operation"]?.toSpanAttribute() == .string("value"))
    }

    @Test
    func unrelatedRecorderDoesNotClaimGlobalInstallation() throws {
        let global = AdaMCPTraceRecorder.activeGlobalRecorder() ?? AdaMCPTraceRecorder()
        try #require(global.installAsGlobalTracerIfPossible())
        let other = AdaMCPTraceRecorder()
        #expect(!other.isInstalledAsGlobalTracer)
        #expect(!other.installAsGlobalTracerIfPossible())
        #expect(global.isInstalledAsGlobalTracer)
        #expect(AdaMCPTraceRecorder.activeGlobalRecorder()?.isInstalledAsGlobalTracer == true)
        #expect(other.statusPayload().objectValue?["recording"]?.boolValue == false)
    }

    @Test
    func realEngineSchedulerRecordsOnlyWhileConsumerIsActive() async throws {
        let recorder = AdaMCPTraceRecorder.activeGlobalRecorder() ?? AdaMCPTraceRecorder()
        try #require(recorder.installAsGlobalTracerIfPossible())
        let originalMode = recorder.tracer.isContinuousRecordingEnabled
        defer { recorder.tracer.setContinuousRecordingEnabled(originalMode) }
        recorder.tracer.setContinuousRecordingEnabled(false)
        let worldName = "trace-runtime-\(UUID().uuidString)"
        let world = World(name: worldName)
        world.insertResource(TraceRunCounter())
        world.addSystem(tracingProbeSystem.self, on: .update)
        await world.runScheduler(.update)
        #expect(!recorder.tracer.finishedSpans.contains {
            $0.attributes["ada.world.name"]?.toSpanAttribute() == .string(worldName)
        })
        do {
            let lease = recorder.tracer.acquireRecordingLease()
            await world.runScheduler(.update)
            withExtendedLifetime(lease) { }
        }
        let spans = recorder.tracer.finishedSpans.filter {
            $0.attributes["ada.world.name"]?.toSpanAttribute() == .string(worldName)
        }
        #expect(spans.contains { $0.operationName.hasPrefix("World.runScheduler.") })
        #expect(spans.contains { $0.operationName.hasPrefix("Scheduler.run.") })
        #expect(spans.contains { $0.operationName.contains("tracingProbe") })
        await world.runScheduler(.update)
        #expect(recorder.tracer.finishedSpans.filter {
            $0.attributes["ada.world.name"]?.toSpanAttribute() == .string(worldName)
        }.count == spans.count)
        #expect(world.getResource(TraceRunCounter.self)?.value == 3)
        #expect(!recorder.tracer.activeSpans.contains {
            $0.attributes["ada.world.name"]?.toSpanAttribute() == .string(worldName)
        })
    }

    @Test
    func engineGateSkipsMetadataAndPreservesContextErrorsAndStartedSpans() async throws {
        let recorder = AdaMCPTraceRecorder.activeGlobalRecorder() ?? AdaMCPTraceRecorder()
        try #require(recorder.installAsGlobalTracerIfPossible())
        let originalMode = recorder.tracer.isContinuousRecordingEnabled
        defer { recorder.tracer.setContinuousRecordingEnabled(originalMode) }
        recorder.tracer.setContinuousRecordingEnabled(false)
        let counts = TraceEvaluationCounts()
        let result = await AdaTrace.span(lazyName: counts.name(), attributes: counts.attributes()) { () async in 42 }
        #expect(result == 42)
        #expect(AdaTrace.span(lazyName: counts.name(), attributes: counts.attributes()) { 7 } == 7)
        let ignored = AdaTrace.startSpan(lazyName: counts.name(), attributes: counts.attributes())
        #expect(!ignored.isRecording)
        ignored.end()
        #expect(counts.total == 0)

        // Preserve the original String API, including throwing name expressions
        // and references to the four-argument startSpan function.
        let legacyStart: (String, String, String, UInt) -> any Span = AdaTrace.startSpan
        #expect(!legacyStart("legacy", #function, #fileID, #line).isRecording)
        let legacyResult = try AdaTrace.span(try legacyName()) { 5 }
        #expect(legacyResult == 5)

        var context = ServiceContext.topLevel
        context[TraceTestContextKey.self] = "preserved"
        do {
            let _: Void = try await ServiceContext.$current.withValue(context) {
                try await AdaTrace.span(lazyName: counts.name()) { span in
                    #expect(!span.isRecording)
                    #expect(span.context[TraceTestContextKey.self] == "preserved")
                    await Task.yield()
                    throw TraceTestError.expected
                }
            }
            Issue.record("Expected body error")
        } catch TraceTestError.expected { }
        #expect(counts.total == 0)

        recorder.tracer.setContinuousRecordingEnabled(true)
        let parentName = "gate-parent-\(UUID().uuidString)"
        let childName = "gate-child-\(UUID().uuidString)"
        await AdaTrace.span(lazyName: parentName, attributes: ["phase": "parent"]) {
            await AdaTrace.span(lazyName: childName, attributes: ["phase": "child"]) { () async in }
            recorder.tracer.setContinuousRecordingEnabled(false)
            await AdaTrace.span(lazyName: "not-recorded") { span async in
                #expect(!span.isRecording)
                #expect(span.context.inMemorySpanContext != nil)
            }
        }
        let spans = recorder.tracer.finishedSpans
        let parent = try #require(spans.first { $0.operationName == parentName })
        let child = try #require(spans.first { $0.operationName == childName })
        #expect(child.traceID == parent.traceID)
        #expect(child.parentSpanID == parent.spanID)
        #expect(parent.attributes["phase"]?.toSpanAttribute() == .string("parent"))
        #expect(child.attributes["phase"]?.toSpanAttribute() == .string("child"))
        #expect(!recorder.tracer.activeSpans.contains { $0.operationName == parentName || $0.operationName == childName })

        recorder.tracer.setContinuousRecordingEnabled(true)
        let errorName = "gate-error-\(UUID().uuidString)"
        do {
            let _: Void = try await AdaTrace.span(lazyName: errorName, attributes: ["phase": "error"]) { () async throws in
                throw TraceTestError.expected
            }
            Issue.record("Expected recorded body error")
        } catch TraceTestError.expected { }
        let failure = try #require(recorder.tracer.finishedSpans.first { $0.operationName == errorName })
        #expect(failure.errors.count == 1)
        #expect(failure.attributes["phase"]?.toSpanAttribute() == .string("error"))
        #expect(!recorder.tracer.activeSpans.contains { $0.operationName == errorName })
    }

    @Test
    func concurrentConsumersReleaseOnlyTheirOwnLease() async {
        let tracer = AdaMCPTracer(continuousRecording: false)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let lease = tracer.acquireRecordingLease()
                    await Task.yield()
                    #expect(tracer.isAutomaticRecordingEnabled)
                    withExtendedLifetime(lease) { }
                }
            }
        }
        #expect(!tracer.isAutomaticRecordingEnabled)
    }

    @Test
    func leasesAndFileSessionsComposeAndRestoreContinuousMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracer = AdaMCPTracer(temporaryDirectory: directory, continuousRecording: false)
        #expect(!tracer.isAutomaticRecordingEnabled)
        var first: AdaMCPTraceLease? = tracer.acquireRecordingLease()
        var second: AdaMCPTraceLease? = tracer.acquireRecordingLease()
        #expect(first != nil && second != nil)
        first = nil
        #expect(tracer.isAutomaticRecordingEnabled)
        _ = try tracer.startFileSession()
        second = nil
        #expect(tracer.isAutomaticRecordingEnabled)
        let span = tracer.startSpan("file-content")
        span.attributes["payload"] = "kept"
        span.end()
        let recorded = try tracer.stopFileSession()
        #expect(recorded.count == 1)
        #expect(recorded.first?.objectValue?["attributes"]?.objectValue?["payload"]?.stringValue == "kept")
        #expect(!tracer.isAutomaticRecordingEnabled)
        tracer.setContinuousRecordingEnabled(true)
        _ = try tracer.startFileSession()
        _ = try tracer.discardFileSession()
        #expect(tracer.isAutomaticRecordingEnabled)
    }

    @Test
    func liveConsumerExpiresAndCaptureStopsWithoutPolling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AdaMCPTraceRecorder(configuration: .init(temporaryDirectory: directory, continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder, liveLeaseDuration: .milliseconds(20))
        _ = try profiler.liveSnapshotPayload()
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
        _ = try profiler.startCapture(arguments: ["durationMs": .int(20)])
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!recorder.tracer.isFileSessionActive)
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
        let capture = try profiler.capturePayload(id: nil)
        #expect(capture.objectValue?["manifest"]?.objectValue?["state"]?.stringValue == "completed")
    }

    @Test
    func frameCaptureCompletesAfterMemoryRingWraps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AdaMCPTraceRecorder(configuration: .init(maxFinishedSpanCount: 1, temporaryDirectory: directory, continuousRecording: false))
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        _ = try profiler.startCapture(arguments: ["frameCount": .int(3)])
        for _ in 0..<3 { recorder.tracer.startSpan("AppWorlds.update").end() }
        recorder.tracer.startSpan("other").end()
        #expect(recorder.tracer.finishedSpanCount == 1)
        let result = try profiler.capturePayload(id: nil)
        #expect(result.objectValue?["manifest"]?.objectValue?["state"]?.stringValue == "completed")
        #expect(result.objectValue?["spans"]?.arrayValue?.count == 4)
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
    }

    @Test
    func runtimeExposesExplicitContinuousRecordingControl() async throws {
        #expect(MCPServerConfiguration().traceRecorder?.tracer.isAutomaticRecordingEnabled == false)
        #expect(AdaMCPTraceRecorder().tracer.isContinuousRecordingEnabled)
        let recorder = AdaMCPTraceRecorder(configuration: .init(continuousRecording: false))
        let app = AppWorlds(main: World())
        let runtime = AdaMCPRuntime(appWorlds: app, registry: MCPIntrospectionRegistry(), renderCaptureService: RenderCaptureService(appWorlds: app), traceRecorder: recorder)
        let enabled = await runtime.callTool(name: "trace.set_enabled", arguments: ["enabled": .bool(true)])
        #expect(enabled.isError != true)
        #expect(recorder.tracer.isContinuousRecordingEnabled)
        let invalid = await runtime.callTool(name: "trace.set_enabled", arguments: ["enabled": .string("false")])
        #expect(invalid.isError == true)
        #expect(recorder.tracer.isContinuousRecordingEnabled)
        let disabled = await runtime.callTool(name: "trace.set_enabled", arguments: ["enabled": .bool(false)])
        #expect(disabled.isError != true)
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
    }

    @Test
    func captureTimerAndDestructionDoNotCloseReplacementFileSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AdaMCPTraceRecorder(configuration: .init(temporaryDirectory: directory, continuousRecording: false))
        var profiler: AdaMCPProfiler? = AdaMCPProfiler(traceRecorder: recorder)
        _ = try profiler?.startCapture(arguments: ["durationMs": .int(20)])
        _ = try recorder.tracer.discardFileSession()
        let replacement = try recorder.tracer.startFileSession()
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.tracer.fileSessionURL == replacement)
        let failed = try profiler?.capturePayload(id: nil)
        #expect(failed?.objectValue?["manifest"]?.objectValue?["state"]?.stringValue == "failed")
        _ = try recorder.tracer.discardFileSession()

        _ = try profiler?.startCapture(arguments: [:])
        _ = try recorder.tracer.discardFileSession()
        let replacementBeforeDeinit = try recorder.tracer.startFileSession()
        profiler = nil
        #expect(recorder.tracer.fileSessionURL == replacementBeforeDeinit)
        #expect(recorder.tracer.isAutomaticRecordingEnabled)
        _ = try recorder.tracer.discardFileSession()
        #expect(!recorder.tracer.isAutomaticRecordingEnabled)
    }
}

private enum TraceTestError: Error { case expected }
private func legacyName() throws -> String { "legacy" }
private enum TraceTestContextKey: ServiceContextKey { typealias Value = String }

private final class TraceEvaluationCounts: Sendable {
    private let count = Mutex(0)
    var total: Int { count.withLock { $0 } }
    func name() -> String { count.withLock { $0 += 1 }; return "unused" }
    func attributes() -> SpanAttributes { count.withLock { $0 += 1 }; return ["unused": true] }
}

struct TraceRunCounter: AdaECS.Resource { var value = 0 }

@System
func tracingProbe(_ counter: ResMut<TraceRunCounter>) {
    counter.value += 1
}
