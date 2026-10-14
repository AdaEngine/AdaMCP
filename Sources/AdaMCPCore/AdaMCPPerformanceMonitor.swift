import AdaECS
import AdaEngine
import Foundation
import InMemoryTracing
import MCP
import Synchronization
import Tracing

public struct AdaMCPPerformanceStatistics: Codable, Sendable, Equatable {
    public let count: Int
    public let meanMs: Double
    public let p95Ms: Double
    public let maxMs: Double
    public let totalMs: Double
    public let sampledPercentile: Bool
}

public struct AdaMCPPerformanceHotspot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let statistics: AdaMCPPerformanceStatistics
}

public struct AdaMCPPerformanceSample: Codable, Sendable, Equatable, Identifiable {
    public var id: Double { timestamp }
    public let timestamp: Double
    public let updatesPerSecond: Double?
    public let update: AdaMCPPerformanceStatistics?
    public let processMemoryBytes: UInt64?
    public let entityCount: Int?
    public let systems: [AdaMCPPerformanceHotspot]
    public let renderNodes: [AdaMCPPerformanceHotspot]
}

public struct AdaMCPPerformanceTarget: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let startedAt: Double
    public var isRunning: Bool
    public var samples: [AdaMCPPerformanceSample]
}

/// Shared between the editor and MCP; no transport is required by an in-process consumer.
@MainActor
public final class AdaMCPProfilerResource: AdaECS.Resource {
    public let profiler: AdaMCPProfiler
    public init(profiler: AdaMCPProfiler) { self.profiler = profiler }
}

/// A fixed-memory accumulator updated before the trace ring can overwrite completed spans.
/// The mutex protects counters across ECS worker tasks. No UI callbacks run under this lock.
final class AdaMCPPerformanceAccumulator: Sendable {
    struct Durations: Sendable {
        var count = 0
        var total = 0.0
        var maximum = 0.0
        var values: [Double] = []
        mutating func add(_ value: Double) {
            count += 1
            total += value
            maximum = max(maximum, value)
            // Exact counts/mean/max; bounded percentile sample under pathological workloads.
            if values.count < 4096 { values.append(value) }
        }
        var statistics: AdaMCPPerformanceStatistics {
            let sorted = values.sorted()
            return .init(count: count, meanMs: !values.isEmpty ? total / Double(count) : 0,
                         p95Ms: sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count - 1) * 0.95))],
                         maxMs: maximum, totalMs: total, sampledPercentile: count > values.count)
        }
    }
    struct Bucket: Sendable {
        var frames = Durations()
        var intervals = Durations()
        var entities: Int?
        var systems: [String: Durations] = [:]
        var renderNodes: [String: Durations] = [:]
    }
    struct State: Sendable {
        var consumers: [String: Int] = [:]
        var buckets: [String: Bucket] = [:]
        var previousStarts: [String: Double] = [:]
    }
    private let state = Mutex(State())

    func acquire(_ id: String) {
        state.withLock {
            if $0.consumers[id, default: 0] == 0 { $0.previousStarts[id] = nil }
            $0.consumers[id, default: 0] += 1
        }
    }
    var hasConsumers: Bool { state.withLock { $0.consumers.values.contains { $0 > 0 } } }
    func release(_ id: String) {
        state.withLock {
            guard let count = $0.consumers[id] else { return }
            $0.consumers[id] = max(0, count - 1)
        }
    }
    func remove(_ id: String) {
        state.withLock { $0.consumers[id] = nil; $0.buckets[id] = nil; $0.previousStarts[id] = nil }
    }
    func record(_ span: FinishedInMemorySpan) {
        guard case .string(let id) = span.attributes["ada.profile.target_id"]?.toSpanAttribute() else { return }
        state.withLock { state in
            guard state.consumers[id, default: 0] > 0 else { return }
            let start = Double(span.startInstant.nanosecondsSinceEpoch) / 1_000_000_000
            let duration = Double(span.endInstant.nanosecondsSinceEpoch - span.startInstant.nanosecondsSinceEpoch) / 1_000_000
            if span.operationName == "AppWorlds.update", case .bool(true) = span.attributes["ada.profile.frame_root"]?.toSpanAttribute() {
                state.buckets[id, default: Bucket()].frames.add(duration)
                if let previous = state.previousStarts[id], start > previous {
                    state.buckets[id, default: Bucket()].intervals.add((start - previous) * 1000)
                }
                state.previousStarts[id] = start
                if case .int64(let count) = span.attributes["ada.profile.entities"]?.toSpanAttribute() {
                    state.buckets[id, default: Bucket()].entities = Int(count)
                }
            } else if span.operationName.hasPrefix("System.execute.") {
                let name = String(span.operationName.dropFirst("System.execute.".count))
                let key = state.buckets[id]?.systems[name] != nil || (state.buckets[id]?.systems.count ?? 0) < 256 ? name : "Other systems"
                state.buckets[id, default: Bucket()].systems[key, default: Durations()].add(duration)
            } else if span.operationName.hasPrefix("RenderGraph.node.") {
                let name = String(span.operationName.dropFirst("RenderGraph.node.".count))
                let key = state.buckets[id]?.renderNodes[name] != nil || (state.buckets[id]?.renderNodes.count ?? 0) < 256 ? name : "Other render nodes"
                state.buckets[id, default: Bucket()].renderNodes[key, default: Durations()].add(duration)
            }
        }
    }
    func drain() -> [String: Bucket] {
        state.withLock { state in
            let result = state.buckets
            state.buckets = [:]
            return result
        }
    }
}

@MainActor
public final class AdaMCPPerformanceMonitor {
    private let tracer: AdaMCPTracer?
    private var targets: [AdaMCPPerformanceTarget] = []
    private var samplingTask: Task<Void, Never>?
    private var remoteLeases: [String: AdaMCPTraceLease] = [:]
    private var remoteTasks: [String: Task<Void, Never>] = [:]

    init(tracer: AdaMCPTracer?) { self.tracer = tracer }
    deinit {
        samplingTask?.cancel()
        for task in remoteTasks.values { task.cancel() }
    }
    public var available: Bool { tracer != nil }
    public var sessions: [AdaMCPPerformanceTarget] { targets }

    @discardableResult
    public func register(title: String, id: String = UUID().uuidString.lowercased()) -> String {
        targets.append(.init(id: id, title: title, startedAt: Date().timeIntervalSince1970, isRunning: true, samples: []))
        // Retain recent stopped sessions, but never evict a running game.
        while targets.filter({ !$0.isRunning }).count > 8,
              let index = targets.firstIndex(where: { !$0.isRunning }) { targets.remove(at: index) }
        return id
    }

    public func target(_ id: String) -> AdaMCPPerformanceTarget? { targets.first { $0.id == id } }

    public func subscribe(targetID: String) throws -> AdaMCPTraceLease {
        guard let target = target(targetID), target.isRunning else { throw AdaMCPError.resourceNotFound(targetID) }
        guard let tracer else { throw AdaMCPError.tracingUnavailable }
        tracer.performance.acquire(targetID)
        let traceLease = tracer.acquireRecordingLease()
        ensureSampling()
        return AdaMCPTraceLease {
            tracer.performance.release(targetID)
            withExtendedLifetime(traceLease) {}
        }
    }

    func renewRemoteSubscription(_ id: String) throws {
        guard target(id)?.isRunning == true else { return }
        if remoteLeases[id] == nil { remoteLeases[id] = try subscribe(targetID: id) }
        remoteTasks[id]?.cancel()
        remoteTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.remoteLeases[id] = nil
            self?.remoteTasks[id] = nil
        }
    }

    func stop(_ id: String) {
        sample()
        if let index = targets.firstIndex(where: { $0.id == id }) { targets[index].isRunning = false }
        remoteTasks.removeValue(forKey: id)?.cancel()
        remoteLeases[id] = nil
        tracer?.performance.remove(id)
    }

    private func ensureSampling() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                self.sample()
                if self.tracer?.performance.hasConsumers != true {
                    self.samplingTask = nil
                    return
                }
            }
        }
    }

    /// Drain once per tick. Repeated UI/MCP reads return the same immutable samples.
    func sample() {
        guard let buckets = tracer?.performance.drain(), !buckets.isEmpty else { return }
        let memory = AdaMCPProfiler.currentResidentBytes()
        let timestamp = Date().timeIntervalSince1970
        for (id, bucket) in buckets {
            guard let index = targets.firstIndex(where: { $0.id == id && $0.isRunning }) else { continue }
            func hotspots(_ values: [String: AdaMCPPerformanceAccumulator.Durations]) -> [AdaMCPPerformanceHotspot] {
                values.map { .init(name: $0.key, statistics: $0.value.statistics) }
                    .sorted { $0.statistics.totalMs > $1.statistics.totalMs }
            }
            let meanInterval = bucket.intervals.statistics.meanMs
            targets[index].samples.append(.init(timestamp: timestamp,
                updatesPerSecond: meanInterval > 0 ? 1000 / meanInterval : nil,
                update: !bucket.frames.values.isEmpty ? bucket.frames.statistics : nil,
                processMemoryBytes: memory > 0 ? memory : nil, entityCount: bucket.entities,
                systems: hotspots(bucket.systems), renderNodes: hotspots(bucket.renderNodes)))
            targets[index].samples.removeAll { $0.timestamp < timestamp - 60 }
            if targets[index].samples.count > 240 { targets[index].samples.removeFirst(targets[index].samples.count - 240) }
        }
    }

    public func snapshotPayload(targetID: String) throws -> Value {
        guard let target = target(targetID) else { throw AdaMCPError.resourceNotFound(targetID) }
        try renewRemoteSubscription(targetID)
        return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(target))
    }
    public func sessionsPayload() throws -> Value {
        let descriptors = targets.map { target in
            AdaMCPPerformanceTarget(id: target.id, title: target.title, startedAt: target.startedAt, isRunning: target.isRunning, samples: [])
        }
        return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(descriptors))
    }
}
