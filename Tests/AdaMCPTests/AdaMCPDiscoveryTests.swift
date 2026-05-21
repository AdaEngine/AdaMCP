import AdaMCPCore
import AdaMCPServer
import Foundation
import Testing

@Suite("AdaMCP Discovery Tests")
struct AdaMCPDiscoveryTests {
    @Test("Publisher writes, refreshes, and removes manifest")
    func publisherWritesRefreshesAndRemovesManifest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let publisher = AdaMCPDiscoveryPublisher(
            id: "test-server",
            directory: directory,
            ttlSeconds: 30
        )
        let configuration = MCPServerConfiguration(
            serverName: "example-app",
            serverVersion: "1.2.3",
            discoveryMetadata: ["workspace": "AdaMCP"]
        )

        try publisher.start(endpointURL: URL(string: "http://127.0.0.1:25102/mcp")!, configuration: configuration)

        let manifestURL = directory.appendingPathComponent("test-server.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let first = try decodeManifest(at: manifestURL)
        #expect(first.schemaVersion == 1)
        #expect(first.id == "test-server")
        #expect(first.serverName == "example-app")
        #expect(first.serverVersion == "1.2.3")
        #expect(first.endpointURL == "http://127.0.0.1:25102/mcp")
        #expect(first.metadata["workspace"] == "AdaMCP")

        try publisher.refresh()
        let second = try decodeManifest(at: manifestURL)
        #expect(second.updatedAt >= first.updatedAt)

        publisher.stop()
        #expect(FileManager.default.fileExists(atPath: manifestURL.path) == false)
    }

    @Test("Discovery helper filters and removes stale manifests")
    func discoveryHelperFiltersAndRemovesStaleManifests() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        try encodeManifest(
            AdaMCPDiscoveryManifest(
                id: "live",
                pid: 1,
                processName: "live-app",
                serverName: "live",
                serverVersion: "1.0.0",
                endpointURL: "http://127.0.0.1:25102/mcp",
                startedAt: now,
                updatedAt: now,
                ttlSeconds: 30,
                metadata: [:]
            ),
            to: directory.appendingPathComponent("live.json")
        )
        try encodeManifest(
            AdaMCPDiscoveryManifest(
                id: "stale",
                pid: 2,
                processName: "stale-app",
                serverName: "stale",
                serverVersion: "1.0.0",
                endpointURL: "http://127.0.0.1:25103/mcp",
                startedAt: now.addingTimeInterval(-60),
                updatedAt: now.addingTimeInterval(-60),
                ttlSeconds: 10,
                metadata: [:]
            ),
            to: directory.appendingPathComponent("stale.json")
        )

        let manifests = AdaMCPDiscovery.liveManifests(in: directory, now: now)
        #expect(manifests.map(\.id) == ["live"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stale.json").path) == false)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaMCPDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func decodeManifest(at url: URL) throws -> AdaMCPDiscoveryManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AdaMCPDiscoveryManifest.self, from: Data(contentsOf: url))
    }

    private func encodeManifest(_ manifest: AdaMCPDiscoveryManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url)
    }
}
