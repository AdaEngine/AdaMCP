import AdaMCPCore
import Foundation
import InMemoryTracing
import MCP
import Testing
import Tracing

@MainActor
@Suite("AdaMCP Profiler Tests")
struct AdaMCPProfilerTests {
    @Test("Frame capture reports percentiles, overlapping work, and dropped presentation")
    func frameCaptureSummary() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaMCPProfilerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let recorder = AdaMCPTraceRecorder(
            tracer: AdaMCPTracer(
                idGenerator: .incrementing,
                maxFinishedSpanCount: 4,
                temporaryDirectory: temporaryDirectory
            ),
            serviceName: "adamcp-profiler-tests",
            scopeName: "AdaMCPProfilerTests"
        )
        let profiler = AdaMCPProfiler(traceRecorder: recorder)
        let started = try profiler.startCapture(arguments: [
            "frameCount": .int(2),
            "frameBudgetMs": .double(1)
        ])
        let captureID = try #require(started.objectValue?["id"]?.stringValue)

        var rejectedConcurrentCapture = false
        do {
            _ = try profiler.startCapture(arguments: [:])
        } catch {
            rejectedConcurrentCapture = true
        }
        #expect(rejectedConcurrentCapture)

        let firstFrame = recorder.tracer.startSpan("AppWorlds.update")
        firstFrame.attributes["ada.profile.category"] = "frame"
        let physics = recorder.tracer.startSpan("System.execute.Physics")
        physics.attributes["ada.profile.category"] = "system"
        physics.attributes["ada.system.name"] = "Physics"
        let animation = recorder.tracer.startSpan("System.execute.Animation")
        animation.attributes["ada.profile.category"] = "system"
        animation.attributes["ada.system.name"] = "Animation"
        try await Task.sleep(for: .milliseconds(3))
        physics.end()
        animation.end()
        firstFrame.end()

        let display = recorder.tracer.startSpan("Display.present")
        display.attributes["ada.profile.category"] = "display"
        display.attributes["ada.display.dropped"] = true
        display.attributes["ada.display.interval_ms"] = 16.67
        display.end()

        let secondFrame = recorder.tracer.startSpan("AppWorlds.update")
        secondFrame.attributes["ada.profile.category"] = "frame"
        try await Task.sleep(for: .milliseconds(2))
        secondFrame.end()

        let capture = try profiler.capturePayload(id: captureID)
        let manifest = try #require(capture.objectValue?["manifest"]?.objectValue)
        let summary = try #require(capture.objectValue?["summary"]?.objectValue)
        let frameTime = try #require(summary["frameTime"]?.objectValue)
        let displaySummary = try #require(summary["display"]?.objectValue)
        let traceEvents = capture.objectValue?["trace"]?.objectValue?["traceEvents"]?.arrayValue ?? []
        let systemTrackIDs = Set(traceEvents.compactMap { event -> Int? in
            guard event.objectValue?["cat"]?.stringValue == "system" else { return nil }
            return event.objectValue?["tid"]?.intValue
        })

        #expect(manifest["state"]?.stringValue == "completed")
        #expect(summary["frameCount"]?.intValue == 2)
        #expect((frameTime["p50Ms"]?.doubleValue ?? 0) <= (frameTime["p95Ms"]?.doubleValue ?? 0))
        #expect((frameTime["p95Ms"]?.doubleValue ?? 0) <= (frameTime["maxMs"]?.doubleValue ?? 0))
        #expect((summary["budgetMissCount"]?.intValue ?? 0) == 2)
        #expect((summary["totalSystemWorkMs"]?.doubleValue ?? 0) > (summary["criticalPathMs"]?.doubleValue ?? 0))
        #expect(displaySummary["droppedFrameCount"]?.intValue == 1)
        #expect(traceEvents.count == 5)
        #expect(systemTrackIDs.count == 2)
        #expect(recorder.tracer.isFileSessionActive == false)
    }

    @Test("Capabilities do not estimate unavailable providers")
    func capabilitiesMarkUnavailableProviders() throws {
        let profiler = AdaMCPProfiler(traceRecorder: nil)
        let providers = try #require(profiler.capabilitiesPayload().objectValue?["providers"]?.objectValue)

        #expect(providers["cpuFrame"]?.objectValue?["supported"]?.boolValue == false)
        #expect(providers["hangs"]?.objectValue?["supported"]?.boolValue == false)
        #expect(providers["allocations"]?.objectValue?["supported"]?.boolValue == false)
        #expect(providers["gpuCounters"]?.objectValue?["supported"]?.boolValue == false)
    }
}
