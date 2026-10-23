import Foundation
import MCP
import Testing

@Suite("Tool metadata")
struct ToolMetadataTests {
    @Test("Tool metadata uses a flat JSON object and preserves arbitrary values")
    func wireFormat() throws {
        let fields: [String: Value] = [
            "sloppy/verification": "build",
            "vendor/nested": ["enabled": true, "values": [1, "two", nil]],
        ]
        let tool = Tool(name: "editor.build.start", inputSchema: ["type": "object"], _meta: Metadata(additionalFields: fields))
        let data = try JSONEncoder().encode(tool)
        let json = try JSONDecoder().decode(Value.self, from: data)
        #expect(json.objectValue?["_meta"] == .object(fields))
        #expect(try JSONDecoder().decode(Tool.self, from: data) == tool)
    }

    @Test("Legacy tools without metadata retain their wire format")
    func legacyTool() throws {
        let data = Data(#"{"name":"legacy","inputSchema":{"type":"object"}}"#.utf8)
        let tool = try JSONDecoder().decode(Tool.self, from: data)
        #expect(tool._meta == nil)
        let encoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(tool))
        #expect(encoded.objectValue?["_meta"] == nil)
        #expect(Tool(name: "legacy", inputSchema: ["type": "object"]) == tool)
    }

    @Test("Non-object metadata is rejected")
    func invalidMetadata() {
        for value in ["[]", "42", #""text""#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Metadata.self, from: Data(value.utf8))
            }
        }
    }

    @Test("tools/list delivers verification metadata through the real client and server", .timeLimit(.minutes(1)))
    func listToolsRoundTrip() async throws {
        let tool = Tool(
            name: "editor.test.start", inputSchema: ["type": "object"],
            annotations: .init(readOnlyHint: false),
            _meta: Metadata(additionalFields: ["sloppy/verification": "test"])
        )
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "metadata-server", version: "1")
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: [tool]) }
        let client = Client(name: "metadata-client", version: "1")
        try await server.start(transport: serverTransport)
        do {
            try await client.connect(transport: clientTransport)
            let (tools, _) = try await client.listTools()
            #expect(tools == [tool])
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await client.disconnect()
        await server.stop()
    }
}
