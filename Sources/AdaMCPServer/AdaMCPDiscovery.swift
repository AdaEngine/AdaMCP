import AdaMCPCore
import Foundation

public struct AdaMCPDiscoveryManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let pid: Int32
    public let processName: String
    public let serverName: String
    public let serverVersion: String
    public let endpointURL: String
    public let startedAt: Date
    public let updatedAt: Date
    public let ttlSeconds: TimeInterval
    public let metadata: [String: String]

    public init(
        schemaVersion: Int = 1,
        id: String,
        pid: Int32,
        processName: String,
        serverName: String,
        serverVersion: String,
        endpointURL: String,
        startedAt: Date,
        updatedAt: Date,
        ttlSeconds: TimeInterval,
        metadata: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.pid = pid
        self.processName = processName
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.endpointURL = endpointURL
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.ttlSeconds = ttlSeconds
        self.metadata = metadata
    }

    public func isLive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) <= ttlSeconds
    }
}

public enum AdaMCPDiscovery {
    public static let environmentVariable = "ADAMCP_DISCOVERY_DIR"
    public static let directoryName = "discovery"

    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[environmentVariable], override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        #if os(macOS)
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent("AdaMCP", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }
        #endif

        if let runtimeDirectory = environment["XDG_RUNTIME_DIR"], runtimeDirectory.isEmpty == false {
            return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
                .appendingPathComponent("AdaMCP", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        return fileManager.temporaryDirectory
            .appendingPathComponent("AdaMCP", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func liveManifests(
        in directory: URL? = nil,
        now: Date = Date(),
        removeStale: Bool = true,
        fileManager: FileManager = .default
    ) -> [AdaMCPDiscoveryManifest] {
        let directory = directory ?? defaultDirectory(fileManager: fileManager)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files.compactMap { url in
            guard url.pathExtension == "json" else {
                return nil
            }
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(AdaMCPDiscoveryManifest.self, from: data) else {
                if removeStale {
                    try? fileManager.removeItem(at: url)
                }
                return nil
            }
            guard manifest.schemaVersion == 1,
                  manifest.endpointURL.isEmpty == false,
                  manifest.isLive(now: now) else {
                if removeStale {
                    try? fileManager.removeItem(at: url)
                }
                return nil
            }
            return manifest
        }.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

public final class AdaMCPDiscoveryPublisher: @unchecked Sendable {
    private struct State {
        let id: String
        let endpointURL: URL
        let serverName: String
        let serverVersion: String
        let metadata: [String: String]
        let startedAt: Date
        let ttlSeconds: TimeInterval
        let manifestURL: URL
    }

    public let id: String
    public let directory: URL
    public let ttlSeconds: TimeInterval

    private let fileManager: FileManager
    private let lock = NSLock()
    private var state: State?
    private var heartbeatTask: Task<Void, Never>?

    public init(
        id: String = UUID().uuidString.lowercased(),
        directory: URL? = nil,
        ttlSeconds: TimeInterval = 15,
        fileManager: FileManager = .default
    ) {
        self.id = id
        self.directory = directory ?? AdaMCPDiscovery.defaultDirectory(fileManager: fileManager)
        self.ttlSeconds = ttlSeconds
        self.fileManager = fileManager
    }

    deinit {
        stop()
    }

    public func start(endpointURL: URL, configuration: MCPServerConfiguration) throws {
        stop()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let state = State(
            id: id,
            endpointURL: endpointURL,
            serverName: configuration.serverName,
            serverVersion: configuration.serverVersion,
            metadata: configuration.discoveryMetadata,
            startedAt: now,
            ttlSeconds: ttlSeconds,
            manifestURL: directory.appendingPathComponent("\(id).json")
        )
        try writeManifest(state: state, updatedAt: now)

        lock.lock()
        self.state = state
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            let interval = max(1, ttlSeconds / 3)
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    break
                }
                try? self.refresh()
            }
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let currentTask = heartbeatTask
        let manifestURL = state?.manifestURL
        heartbeatTask = nil
        state = nil
        lock.unlock()

        currentTask?.cancel()
        if let manifestURL {
            try? fileManager.removeItem(at: manifestURL)
        }
    }

    public func refresh() throws {
        lock.lock()
        let currentState = state
        lock.unlock()

        guard let currentState else {
            return
        }
        try writeManifest(state: currentState, updatedAt: Date())
    }

    private func writeManifest(state: State, updatedAt: Date) throws {
        let manifest = AdaMCPDiscoveryManifest(
            id: state.id,
            pid: ProcessInfo.processInfo.processIdentifier,
            processName: ProcessInfo.processInfo.processName,
            serverName: state.serverName,
            serverVersion: state.serverVersion,
            endpointURL: state.endpointURL.absoluteString,
            startedAt: state.startedAt,
            updatedAt: updatedAt,
            ttlSeconds: state.ttlSeconds,
            metadata: state.metadata
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let temporaryURL = state.manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(state.manifestURL.lastPathComponent).tmp")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: state.manifestURL.path) {
            _ = try fileManager.replaceItemAt(state.manifestURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: state.manifestURL)
        }
    }
}
