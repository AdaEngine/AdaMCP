import Foundation
import Logging
@preconcurrency import SystemPackage

public enum Value: Codable, Sendable, Equatable, ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: Value...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, Value)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    public init<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(AnyEncodable(value))
        self = try JSONDecoder().decode(Value.self, from: data)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [Value]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: Value]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Value].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Value].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

private struct AnyEncodable: Encodable {
    let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

public struct Tool: Codable, Sendable, Equatable {
    public struct Annotations: Codable, Sendable, Equatable {
        public var readOnlyHint: Bool?
        public var destructiveHint: Bool?
        public var idempotentHint: Bool?
        public var openWorldHint: Bool?

        public init(readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }
    }

    public enum Content: Codable, Sendable, Equatable {
        case text(text: String, annotations: Value?, _meta: Value?)

        private enum CodingKeys: String, CodingKey {
            case type, text, annotations
            case meta = "_meta"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(
                    text: try container.decode(String.self, forKey: .text),
                    annotations: try container.decodeIfPresent(Value.self, forKey: .annotations),
                    _meta: try container.decodeIfPresent(Value.self, forKey: .meta)
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported content type \(type).")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text, let annotations, let meta):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(meta, forKey: .meta)
            }
        }
    }

    public var name: String
    public var description: String?
    public var inputSchema: Value
    public var annotations: Annotations?

    public init(name: String, description: String? = nil, inputSchema: Value, annotations: Annotations? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

public struct Resource: Codable, Sendable, Equatable {
    public struct Template: Codable, Sendable, Equatable {
        public var uriTemplate: String
        public var name: String
        public var title: String?
        public var description: String?
        public var mimeType: String?

        public init(uriTemplate: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil) {
            self.uriTemplate = uriTemplate
            self.name = name
            self.title = title
            self.description = description
            self.mimeType = mimeType
        }
    }

    public enum Content: Codable, Sendable, Equatable {
        case text(String, uri: String, mimeType: String?)

        private enum CodingKeys: String, CodingKey {
            case uri, mimeType, text
        }

        public var text: String? {
            if case .text(let text, _, _) = self { return text }
            return nil
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self = .text(
                try container.decode(String.self, forKey: .text),
                uri: try container.decode(String.self, forKey: .uri),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text, let uri, let mimeType):
                try container.encode(uri, forKey: .uri)
                try container.encodeIfPresent(mimeType, forKey: .mimeType)
                try container.encode(text, forKey: .text)
            }
        }
    }

    public var name: String
    public var uri: String
    public var description: String?
    public var mimeType: String?

    public init(name: String, uri: String, description: String? = nil, mimeType: String? = nil) {
        self.name = name
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
    }
}

public enum MCPError: LocalizedError, Sendable {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case internalError(String)
    case connectionClosed

    public var code: Int {
        switch self {
        case .parseError: -32700
        case .invalidRequest: -32600
        case .methodNotFound: -32601
        case .internalError, .connectionClosed: -32603
        }
    }

    public var errorDescription: String? {
        switch self {
        case .parseError(let message), .invalidRequest(let message), .methodNotFound(let message), .internalError(let message):
            message
        case .connectionClosed:
            "Connection closed"
        }
    }
}

public enum Version {
    public static let latest = "2025-11-25"
    public static let supported = ["2025-11-25", "2025-06-18", "2025-03-26"]
}

public enum HTTPHeaderName {
    public static let sessionID = "MCP-Session-Id"
    public static let protocolVersion = "MCP-Protocol-Version"
    public static let lastEventID = "Last-Event-ID"
    public static let accept = "Accept"
    public static let contentType = "Content-Type"
    public static let authorization = "Authorization"
    public static let cacheControl = "Cache-Control"
    public static let connection = "Connection"
    public static let allow = "Allow"
}

public enum ContentType {
    public static let json = "application/json"
    public static let sse = "text/event-stream"
}

public protocol SessionIDGenerator: Sendable {
    func generateSessionID() -> String
}

public struct UUIDSessionIDGenerator: SessionIDGenerator {
    public init() {}
    public func generateSessionID() -> String { UUID().uuidString }
}

public struct HTTPRequest: Sendable {
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let path: String?

    public init(method: String, headers: [String: String] = [:], body: Data? = nil, path: String? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
        self.path = path
    }

    public func header(_ name: String) -> String? {
        let needle = name.lowercased()
        return headers.first { $0.key.lowercased() == needle }?.value
    }
}

public enum HTTPResponse: Sendable {
    case accepted(headers: [String: String] = [:])
    case ok(headers: [String: String] = [:])
    case data(Data, headers: [String: String] = [:])
    case stream(AsyncThrowingStream<Data, Swift.Error>, headers: [String: String] = [:])
    case error(statusCode: Int, MCPError, sessionID: String? = nil, extraHeaders: [String: String] = [:])

    public var statusCode: Int {
        switch self {
        case .accepted: 202
        case .ok, .data, .stream: 200
        case .error(let statusCode, _, _, _): statusCode
        }
    }

    public var headers: [String: String] {
        switch self {
        case .accepted(let headers), .ok(let headers), .data(_, let headers), .stream(_, let headers):
            return headers
        case .error(_, _, let sessionID, let extraHeaders):
            var headers = [HTTPHeaderName.contentType: ContentType.json]
            if let sessionID {
                headers[HTTPHeaderName.sessionID] = sessionID
            }
            headers.merge(extraHeaders) { _, new in new }
            return headers
        }
    }

    public var bodyData: Data? {
        switch self {
        case .accepted, .ok, .stream:
            return nil
        case .data(let data, _):
            return data
        case .error(_, let error, _, _):
            let payload = JSONRPCErrorResponse(id: .null, error: .init(code: error.code, message: error.localizedDescription))
            return try? JSONEncoder().encode(payload)
        }
    }
}

public protocol Transport: Actor {
    nonisolated var logger: Logger { get }
    func connect() async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}

public enum ListTools: MCPMethod {
    public static let name = "tools/list"
    public struct Params: Codable, Sendable { public init() {} }
    public struct Result: Codable, Sendable {
        public var tools: [Tool]
        public init(tools: [Tool]) { self.tools = tools }
    }
}

public enum CallTool: MCPMethod {
    public static let name = "tools/call"
    public struct Params: Codable, Sendable {
        public var name: String
        public var arguments: [String: Value]?
        public init(name: String, arguments: [String: Value]? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }
    public struct Result: Codable, Sendable {
        public var content: [Tool.Content]
        public var isError: Bool?
        public init(content: [Tool.Content], isError: Bool? = nil) {
            self.content = content
            self.isError = isError
        }
    }
}

public enum ListResources: MCPMethod {
    public static let name = "resources/list"
    public struct Params: Codable, Sendable { public init() {} }
    public struct Result: Codable, Sendable {
        public var resources: [Resource]
        public init(resources: [Resource]) { self.resources = resources }
    }
}

public enum ListResourceTemplates: MCPMethod {
    public static let name = "resources/templates/list"
    public struct Params: Codable, Sendable { public init() {} }
    public struct Result: Codable, Sendable {
        public var templates: [Resource.Template]
        public init(templates: [Resource.Template]) { self.templates = templates }
    }
}

public enum ReadResource: MCPMethod {
    public static let name = "resources/read"
    public struct Params: Codable, Sendable {
        public var uri: String
        public init(uri: String) { self.uri = uri }
    }
    public struct Result: Codable, Sendable {
        public var contents: [Resource.Content]
        public init(contents: [Resource.Content]) { self.contents = contents }
    }
}

public protocol MCPMethod {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var name: String { get }
}

public actor Server {
    public struct Capabilities: Codable, Sendable {
        public struct Resources: Codable, Sendable {
            public var listChanged: Bool?
            public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
        }
        public struct Tools: Codable, Sendable {
            public var listChanged: Bool?
            public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
        }
        public var resources: Resources?
        public var tools: Tools?
        public init(resources: Resources? = nil, tools: Tools? = nil) {
            self.resources = resources
            self.tools = tools
        }
    }

    public let name: String
    public let version: String
    public let instructions: String?
    public let capabilities: Capabilities

    private var transport: (any Transport)?
    private var receiveTask: Task<Void, Never>?
    private var handlers: [String: @Sendable (Value?) async throws -> Value] = [:]

    public init(name: String, version: String, instructions: String? = nil, capabilities: Capabilities = .init()) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.capabilities = capabilities
    }

    public func withMethodHandler<M: MCPMethod>(_ method: M.Type, handler: @escaping @Sendable (M.Params) async throws -> M.Result) {
        handlers[M.name] = { params in
            let decoded = try Self.decodeParams(M.Params.self, from: params)
            return try Value(try await handler(decoded))
        }
    }

    public func start(transport: any Transport) async throws {
        self.transport = transport
        try await transport.connect()
        receiveTask = Task { [transport] in
            do {
                for try await data in await transport.receive() {
                    await self.handle(data, transport: transport)
                }
            } catch {
                await self.stop()
            }
        }
    }

    public func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport?.disconnect()
        transport = nil
    }

    private func handle(_ data: Data, transport: any Transport) async {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else {
            try? await transport.send(Self.errorResponse(id: .null, error: .parseError("Parse error")))
            return
        }

        guard let id = request.id else {
            return
        }

        do {
            let result: Value
            if request.method == "initialize" {
                result = try Value(InitializeResult(
                    protocolVersion: request.params?.objectValue?["protocolVersion"]?.stringValue ?? Version.latest,
                    capabilities: capabilities,
                    serverInfo: .init(name: name, version: version),
                    instructions: instructions
                ))
            } else if let handler = handlers[request.method] {
                result = try await handler(request.params)
            } else {
                throw MCPError.methodNotFound("Method not found: \(request.method)")
            }
            try await transport.send(Self.resultResponse(id: id, result: result))
        } catch let error as MCPError {
            try? await transport.send(Self.errorResponse(id: id, error: error))
        } catch {
            try? await transport.send(Self.errorResponse(id: id, error: .internalError(error.localizedDescription)))
        }
    }

    private static func decodeParams<T: Decodable>(_ type: T.Type, from value: Value?) throws -> T {
        let data = try JSONEncoder().encode(value ?? .object([:]))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func resultResponse(id: Value, result: Value) throws -> Data {
        try JSONEncoder().encode(JSONRPCResultResponse(id: id, result: result))
    }

    private static func errorResponse(id: Value, error: MCPError) throws -> Data {
        try JSONEncoder().encode(JSONRPCErrorResponse(id: id, error: .init(code: error.code, message: error.localizedDescription)))
    }
}

public actor Client {
    public let name: String
    public let version: String
    private var transport: (any Transport)?
    private var receiveTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<Value, Error>] = [:]

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    @discardableResult
    public func connect(transport: any Transport) async throws -> InitializeResult {
        self.transport = transport
        try await transport.connect()
        receiveTask = Task { [transport] in
            do {
                for try await data in await transport.receive() {
                    await self.handle(data)
                }
            } catch {
                await self.disconnect()
            }
        }
        return try await request(
            "initialize",
            params: [
                "protocolVersion": .string(Version.latest),
                "clientInfo": .object(["name": .string(name), "version": .string(version)]),
                "capabilities": .object([:])
            ],
            as: InitializeResult.self
        )
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport?.disconnect()
        transport = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.connectionClosed)
        }
        pending.removeAll()
    }

    public func listTools() async throws -> ([Tool], Value?) {
        let result = try await request(ListTools.name, params: [:], as: ListTools.Result.self)
        return (result.tools, nil)
    }

    public func listResources() async throws -> ([Resource], Value?) {
        let result = try await request(ListResources.name, params: [:], as: ListResources.Result.self)
        return (result.resources, nil)
    }

    public func listResourceTemplates() async throws -> ([Resource.Template], Value?) {
        let result = try await request(ListResourceTemplates.name, params: [:], as: ListResourceTemplates.Result.self)
        return (result.templates, nil)
    }

    public func readResource(uri: String) async throws -> [Resource.Content] {
        let result = try await request(ReadResource.name, params: ["uri": .string(uri)], as: ReadResource.Result.self)
        return result.contents
    }

    public func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result {
        try await request(CallTool.name, params: ["name": .string(name), "arguments": .object(arguments)], as: CallTool.Result.self)
    }

    private func request<T: Decodable>(_ method: String, params: [String: Value], as type: T.Type) async throws -> T {
        guard let transport else {
            throw MCPError.connectionClosed
        }

        let id = nextID
        nextID += 1
        let idKey = String(id)
        let response = try await withCheckedThrowingContinuation { continuation in
            pending[idKey] = continuation
            let request = JSONRPCRequest(id: .int(id), method: method, params: .object(params))
            do {
                let data = try JSONEncoder().encode(request)
                Task {
                    do {
                        try await transport.send(data)
                    } catch {
                        await self.failPending(idKey, error: error)
                    }
                }
            } catch {
                pending.removeValue(forKey: idKey)
                continuation.resume(throwing: error)
            }
        }

        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func failPending(_ id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handle(_ data: Data) {
        if let response = try? JSONDecoder().decode(JSONRPCResultResponse.self, from: data) {
            pending.removeValue(forKey: response.idKey)?.resume(returning: response.result)
            return
        }
        if let response = try? JSONDecoder().decode(JSONRPCErrorResponse.self, from: data) {
            pending.removeValue(forKey: response.idKey)?.resume(throwing: MCPError.internalError(response.error.message))
        }
    }
}

public struct InitializeResult: Codable, Sendable {
    public struct ServerInfo: Codable, Sendable {
        public var name: String
        public var version: String
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public var protocolVersion: String
    public var capabilities: Server.Capabilities
    public var serverInfo: ServerInfo
    public var instructions: String?

    public init(protocolVersion: String, capabilities: Server.Capabilities, serverInfo: ServerInfo, instructions: String? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

public actor InMemoryTransport: Transport {
    public nonisolated let logger: Logger
    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private weak var peer: InMemoryTransport?
    private var isConnected = false

    public init(logger: Logger? = nil) {
        self.logger = logger ?? Logger(label: "mcp.transport.memory")
        let pair = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = pair.stream
        self.incomingContinuation = pair.continuation
    }

    public static func createConnectedPair() async -> (InMemoryTransport, InMemoryTransport) {
        let first = InMemoryTransport()
        let second = InMemoryTransport()
        await first.setPeer(second)
        await second.setPeer(first)
        return (first, second)
    }

    private func setPeer(_ peer: InMemoryTransport) {
        self.peer = peer
    }

    public func connect() async throws {
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
        incomingContinuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard isConnected else { throw MCPError.connectionClosed }
        await peer?.yield(data)
    }

    private func yield(_ data: Data) {
        incomingContinuation.yield(data)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }
}

public actor StdioTransport: Transport {
    public nonisolated let logger: Logger
    private let input: FileDescriptor
    private let output: FileDescriptor
    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var readTask: Task<Void, Never>?

    public init(input: FileDescriptor = .standardInput, output: FileDescriptor = .standardOutput, logger: Logger? = nil) {
        self.input = input
        self.output = output
        self.logger = logger ?? Logger(label: "mcp.transport.stdio")
        let pair = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = pair.stream
        self.incomingContinuation = pair.continuation
    }

    public func connect() async throws {
        readTask = Task.detached { [input, incomingContinuation] in
            do {
                while Task.isCancelled == false {
                    let data = try Self.readFrame(from: input)
                    incomingContinuation.yield(data)
                }
            } catch {
                incomingContinuation.finish()
            }
        }
    }

    public func disconnect() async {
        readTask?.cancel()
        readTask = nil
        try? input.close()
        incomingContinuation.finish()
    }

    public func send(_ data: Data) async throws {
        var frame = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        frame.append(data)
        try Self.writeAll(frame, to: output)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    private static func readFrame(from input: FileDescriptor) throws -> Data {
        var header = Data()
        while header.range(of: Data([13, 10, 13, 10])) == nil {
            var byte = [UInt8](repeating: 0, count: 1)
            let count = try byte.withUnsafeMutableBytes { buffer in
                try input.read(into: buffer)
            }
            if count == 0 { throw MCPError.connectionClosed }
            header.append(byte[0])
        }
        guard let text = String(data: header, encoding: .utf8) else {
            throw MCPError.parseError("Invalid stdio frame header")
        }
        let length = text.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
        guard let length else {
            throw MCPError.parseError("Missing Content-Length header")
        }
        var body = Data()
        while body.count < length {
            var chunk = [UInt8](repeating: 0, count: min(8192, length - body.count))
            let count = try chunk.withUnsafeMutableBytes { buffer in
                try input.read(into: buffer)
            }
            if count == 0 { throw MCPError.connectionClosed }
            body.append(chunk, count: count)
        }
        return body
    }

    private static func writeAll(_ data: Data, to output: FileDescriptor) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = try output.write(UnsafeRawBufferPointer(
                    start: bytes.baseAddress?.advanced(by: written),
                    count: bytes.count - written
                ))
                if count == 0 { throw MCPError.connectionClosed }
                written += count
            }
        }
    }
}

public actor StatefulHTTPServerTransport: Transport {
    public nonisolated let logger: Logger
    private let sessionIDGenerator: any SessionIDGenerator
    private var sessionID: String?
    private var terminated = false
    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var requestContinuations: [String: AsyncThrowingStream<Data, Swift.Error>.Continuation] = [:]

    public init(sessionIDGenerator: any SessionIDGenerator = UUIDSessionIDGenerator(), logger: Logger? = nil) {
        self.sessionIDGenerator = sessionIDGenerator
        self.logger = logger ?? Logger(label: "mcp.transport.http.server")
        let pair = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = pair.stream
        self.incomingContinuation = pair.continuation
    }

    public func connect() async throws {}

    public func disconnect() async {
        terminated = true
        for continuation in requestContinuations.values {
            continuation.finish()
        }
        requestContinuations.removeAll()
        incomingContinuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard let message = try? JSONDecoder().decode(JSONRPCResultResponse.self, from: data) else {
            return
        }
        let event = Self.sseEvent(data)
        guard let continuation = requestContinuations.removeValue(forKey: message.idKey) else {
            return
        }
        continuation.yield(event)
        continuation.finish()
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard terminated == false else {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session has been terminated"), sessionID: sessionID)
        }

        switch request.method.uppercased() {
        case "POST":
            guard let body = request.body else {
                return .error(statusCode: 400, .parseError("Empty request body"), sessionID: sessionID)
            }
            guard let rpc = try? JSONDecoder().decode(JSONRPCRequest.self, from: body) else {
                return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"), sessionID: sessionID)
            }
            if rpc.method == "initialize", sessionID == nil {
                sessionID = sessionIDGenerator.generateSessionID()
            }
            guard let id = rpc.id else {
                incomingContinuation.yield(body)
                return .accepted(headers: sessionHeaders())
            }
            let pair = AsyncThrowingStream<Data, Swift.Error>.makeStream()
            requestContinuations[id.key] = pair.continuation
            incomingContinuation.yield(body)
            var headers = sessionHeaders()
            headers[HTTPHeaderName.contentType] = ContentType.sse
            headers[HTTPHeaderName.cacheControl] = "no-cache, no-transform"
            headers[HTTPHeaderName.connection] = "keep-alive"
            return .stream(pair.stream, headers: headers)
        case "DELETE":
            await disconnect()
            return .ok(headers: sessionHeaders())
        default:
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                sessionID: sessionID,
                extraHeaders: [HTTPHeaderName.allow: "GET, POST, DELETE"]
            )
        }
    }

    private func sessionHeaders() -> [String: String] {
        if let sessionID {
            [HTTPHeaderName.sessionID: sessionID]
        } else {
            [:]
        }
    }

    private static func sseEvent(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        return Data("event: message\ndata: \(text)\n\n".utf8)
    }
}

private struct JSONRPCRequest: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Value?
    var method: String
    var params: Value?
}

private struct JSONRPCResultResponse: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Value
    var result: Value

    var idKey: String { id.key }
}

private struct JSONRPCErrorResponse: Codable, Sendable {
    struct ErrorPayload: Codable, Sendable {
        var code: Int
        var message: String
    }

    var jsonrpc = "2.0"
    var id: Value
    var error: ErrorPayload

    var idKey: String { id.key }
}

private extension Value {
    var key: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): value
        case .double(let value): String(value)
        case .bool(let value): String(value)
        case .null: "null"
        case .array, .object: String(describing: self)
        }
    }
}
