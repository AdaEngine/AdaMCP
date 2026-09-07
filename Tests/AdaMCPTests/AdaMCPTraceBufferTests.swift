import AdaMCPCore
import Foundation
import InMemoryTracing
import Testing
import Tracing

struct AdaMCPTraceBufferTests {
    @Test(arguments: [0, 1, 3, 1_000])
    func retainsNewestSpansInCompletionOrder(capacity: Int) {
        let tracer = AdaMCPTracer(idGenerator: .incrementing, maxFinishedSpanCount: capacity)
        let count = capacity * 3 + 7
        for index in 0..<count {
            tracer.startSpan("span-\(index)").end()
        }
        #expect(tracer.finishedSpans.map(\.operationName) == (count - capacity..<count).map { "span-\($0)" })
        #expect(tracer.finishedSpanCount == capacity)
        #expect(tracer.activeSpanCount == 0)
        #expect(tracer.droppedSpanCount == count - capacity)

        let snapshot = tracer.finishedSpans
        tracer.clearFinishedSpans()
        #expect(tracer.finishedSpanCount == 0)
        #expect(tracer.droppedSpanCount == 0)
        tracer.startSpan("after-clear").end()
        #expect(tracer.finishedSpans.map(\.operationName) == (capacity > 0 ? ["after-clear"] : []))
        #expect(snapshot.map(\.operationName) == (count - capacity..<count).map { "span-\($0)" })
    }

    @Test
    func snapshotSurvivesFurtherWrapsAndSpansFinishOutOfOrder() {
        let tracer = AdaMCPTracer(idGenerator: .incrementing, maxFinishedSpanCount: 3)
        let first = tracer.startSpan("first")
        tracer.startSpan("second").end()
        first.end()
        tracer.startSpan("third").end()
        let snapshot = tracer.finishedSpans
        for index in 0..<10 {
            tracer.startSpan("later-\(index)").end()
        }
        #expect(snapshot.map(\.operationName) == ["second", "first", "third"])
        #expect(tracer.finishedSpans.map(\.operationName) == ["later-7", "later-8", "later-9"])
        #expect(tracer.droppedSpanCount == 10)
    }

    @Test
    func concurrentCompletionKeepsBoundedUniqueSpans() async {
        let tracer = AdaMCPTracer(maxFinishedSpanCount: 64)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<128 {
                        tracer.startSpan("\(worker)-\(index)").end()
                    }
                }
            }
        }
        #expect(tracer.finishedSpanCount == 64)
        #expect(tracer.droppedSpanCount == 960)
        #expect(tracer.activeSpanCount == 0)
        #expect(Set(tracer.finishedSpans.map(\.operationName)).count == 64)
    }

    @Test
    func spanIDsHaveExpectedHexEncoding() {
        let generator = AdaMCPTraceRecorder.makeIDGenerator()
        for _ in 0..<100 {
            let traceID = generator.nextTraceID()
            let spanID = generator.nextSpanID()
            #expect(traceID.count == 32)
            #expect(spanID.count == 16)
            #expect(traceID.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(spanID.allSatisfy { "0123456789abcdef".contains($0) })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_PERFORMANCE_BENCHMARK"] == "1"))
    func measureSaturatedTraceBuffer() {
        let tracer = AdaMCPTracer(maxFinishedSpanCount: 1_000)
        for _ in 0..<1_000 { tracer.startSpan("warmup").end() }
        let clock = ContinuousClock()
        let duration = clock.measure {
            for _ in 0..<30_000 { tracer.startSpan("System.execute.Test").end() }
        }
        print("PERFORMANCE trace-buffer 30000 spans: \(duration)")
        #expect(tracer.finishedSpanCount == 1_000)
        #expect(tracer.droppedSpanCount == 30_000)
    }
}
