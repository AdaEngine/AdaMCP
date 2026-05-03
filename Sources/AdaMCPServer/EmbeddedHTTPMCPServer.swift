import AdaMCPCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import MCP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

actor EmbeddedHTTPMCPServer {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var endpoint: String
        var sessionTimeout: TimeInterval

        init(
            host: String = "127.0.0.1",
            port: Int = 0,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
        }
    }

    typealias ServerFactory = @Sendable (String) async throws -> Server

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    nonisolated let logger: Logger

    private var listener: FoundationHTTPListener?
    private var sessions: [String: SessionContext] = [:]
    private var cleanupTask: Task<Void, Never>?

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(
        configuration: Configuration,
        serverFactory: @escaping ServerFactory,
        logger: Logger = Logger(label: "org.adaengine.mcp.http")
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.logger = logger
    }

    func start() async throws -> URL {
        if let listener {
            return try endpointURL(port: listener.port)
        }

        let listener = try FoundationHTTPListener(configuration: configuration, app: self, logger: logger)
        self.listener = listener
        listener.start()

        cleanupTask = Task {
            await self.sessionCleanupLoop()
        }

        return try endpointURL(port: listener.port)
    }

    func stop() async {
        cleanupTask?.cancel()
        cleanupTask = nil

        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
        sessions.removeAll()

        listener?.stop()
        listener = nil
    }

    private func endpointURL(port: Int) throws -> URL {
        let host = configuration.host == "0.0.0.0" ? "127.0.0.1" : configuration.host
        guard let url = URL(string: "http://\(host):\(port)\(configuration.endpoint)") else {
            throw AdaMCPError.screenshotUnavailable("Failed to construct HTTP endpoint URL.")
        }
        return url
    }

    private static func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else {
            return false
        }
        return method == "initialize"
    }

    fileprivate func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String

        func generateSessionID() -> String {
            sessionID
        }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            logger: logger
        )

        do {
            let server = try await serverFactory(sessionID)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return response
        } catch let error as MCPError {
            await transport.disconnect()
            return .error(statusCode: 500, error)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError(error.localizedDescription))
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        await session.transport.disconnect()
    }

    private func sessionCleanupLoop() async {
        while Task.isCancelled == false {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled {
                break
            }
            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout
            }
            for sessionID in expired.keys {
                await closeSession(sessionID)
            }
        }
    }
}

private final class FoundationHTTPListener: @unchecked Sendable {
    let port: Int

    private let socket: SocketDescriptor
    private let configuration: EmbeddedHTTPMCPServer.Configuration
    private let app: EmbeddedHTTPMCPServer
    private let logger: Logger
    private let isRunning = LockedValue(true)
    private var acceptTask: Task<Void, Never>?

    init(
        configuration: EmbeddedHTTPMCPServer.Configuration,
        app: EmbeddedHTTPMCPServer,
        logger: Logger
    ) throws {
        let socket = try SocketDescriptor.openListener(host: configuration.host, port: configuration.port)
        self.socket = socket
        self.port = try socket.boundPort()
        self.configuration = configuration
        self.app = app
        self.logger = logger
    }

    func start() {
        acceptTask = Task.detached { [socket, app, configuration, logger, isRunning] in
            while isRunning.value {
                do {
                    let clientSocket = try socket.accept()
                    Task.detached {
                        await FoundationHTTPConnection(
                            socket: clientSocket,
                            app: app,
                            endpoint: configuration.endpoint,
                            logger: logger
                        ).run()
                    }
                } catch {
                    if isRunning.value {
                        logger.error("AdaMCP HTTP accept failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func stop() {
        isRunning.value = false
        socket.close()
        acceptTask?.cancel()
        acceptTask = nil
    }
}

private struct FoundationHTTPConnection: Sendable {
    let socket: SocketDescriptor
    let app: EmbeddedHTTPMCPServer
    let endpoint: String
    let logger: Logger

    func run() async {
        defer { socket.close() }

        do {
            let rawRequest = try socket.readHTTPRequest()
            let requestPath = rawRequest.path.split(separator: "?").first.map(String.init) ?? rawRequest.path
            guard requestPath == endpoint else {
                try await socket.writeResponse(.error(statusCode: 404, .invalidRequest("Not Found")))
                return
            }

            let request = HTTPRequest(
                method: rawRequest.method,
                headers: rawRequest.headers,
                body: rawRequest.body,
                path: requestPath
            )
            let response = await app.handleHTTPRequest(request)
            try await socket.writeResponse(response)
        } catch {
            logger.debug("AdaMCP HTTP connection closed: \(error.localizedDescription)")
        }
    }
}

private struct RawHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private struct SocketDescriptor: Sendable {
    #if canImport(WinSDK)
    typealias Handle = SOCKET
    #else
    typealias Handle = Int32
    #endif

    let rawValue: Handle

    static func openListener(host: String, port: Int) throws -> SocketDescriptor {
        #if canImport(WinSDK)
        try WindowsSocketRuntime.start()
        let descriptor = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        guard descriptor != INVALID_SOCKET else {
            throw SocketError.operationFailed("socket")
        }
        #elseif canImport(Darwin) || canImport(Glibc)
        let descriptor = socket(AF_INET, socketStreamType, 0)
        guard descriptor >= 0 else {
            throw SocketError.operationFailed("socket")
        }
        #else
        throw SocketError.unsupportedPlatform
        #endif

        let socket = SocketDescriptor(rawValue: descriptor)
        do {
            try socket.configureReusable()
            try socket.bind(host: host, port: port)
            #if canImport(WinSDK)
            guard WinSDK.listen(descriptor, 256) == 0 else {
                throw SocketError.operationFailed("listen")
            }
            #else
            guard listen(descriptor, 256) == 0 else {
                throw SocketError.operationFailed("listen")
            }
            #endif
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    func accept() throws -> SocketDescriptor {
        #if canImport(WinSDK)
        let descriptor = WinSDK.accept(rawValue, nil, nil)
        guard descriptor != INVALID_SOCKET else {
            throw SocketError.operationFailed("accept")
        }
        return SocketDescriptor(rawValue: descriptor)
        #elseif canImport(Darwin) || canImport(Glibc)
        let descriptor = DarwinBridge.accept(rawValue, nil, nil)
        guard descriptor >= 0 else {
            throw SocketError.operationFailed("accept")
        }
        let socket = SocketDescriptor(rawValue: descriptor)
        try socket.disableSIGPIPE()
        return socket
        #else
        throw SocketError.unsupportedPlatform
        #endif
    }

    func close() {
        #if canImport(WinSDK)
        _ = WinSDK.closesocket(rawValue)
        #elseif canImport(Darwin) || canImport(Glibc)
        _ = DarwinBridge.close(rawValue)
        #endif
    }

    func readHTTPRequest() throws -> RawHTTPRequest {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        let maxHeaderBytes = 64 * 1024
        let maxBodyBytes = 16 * 1024 * 1024

        while headerEnd == nil {
            try readChunk(into: &data)
            if data.count > maxHeaderBytes {
                throw SocketError.invalidRequest("HTTP header is too large.")
            }
            headerEnd = data.range(of: Data([13, 10, 13, 10]))
        }

        guard let headerEnd else {
            throw SocketError.invalidRequest("Missing HTTP header terminator.")
        }

        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw SocketError.invalidRequest("HTTP headers are not UTF-8.")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw SocketError.invalidRequest("Missing request line.")
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            throw SocketError.invalidRequest("Malformed request line.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let contentLength = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard contentLength <= maxBodyBytes else {
            throw SocketError.invalidRequest("HTTP body is too large.")
        }

        let bodyStart = headerEnd.upperBound
        let currentBodyBytes = data.count - bodyStart
        if currentBodyBytes < contentLength {
            while data.count - bodyStart < contentLength {
                try readChunk(into: &data)
            }
        }

        let body: Data?
        if contentLength > 0 {
            body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = nil
        }

        return RawHTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: body
        )
    }

    func writeResponse(_ response: HTTPResponse) async throws {
        switch response {
        case .stream(let stream, _):
            var headers = response.headers
            headers["Connection"] = "close"
            try writeHTTPHead(statusCode: response.statusCode, headers: headers)
            for try await chunk in stream {
                try writeAll(chunk)
            }
        default:
            let body = response.bodyData
            var headers = response.headers
            headers["Connection"] = "close"
            if let body {
                headers["Content-Length"] = "\(body.count)"
            } else {
                headers["Content-Length"] = "0"
            }
            try writeHTTPHead(statusCode: response.statusCode, headers: headers)
            if let body {
                try writeAll(body)
            }
        }
    }

    private static var socketStreamType: Int32 {
        #if canImport(Darwin)
        SOCK_STREAM
        #elseif canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        0
        #endif
    }

    private func configureReusable() throws {
        var value: Int32 = 1
        #if canImport(WinSDK)
        guard WinSDK.setsockopt(rawValue, SOL_SOCKET, SO_REUSEADDR, &value, Int32(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketError.operationFailed("setsockopt(SO_REUSEADDR)")
        }
        #else
        guard setsockopt(rawValue, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketError.operationFailed("setsockopt(SO_REUSEADDR)")
        }
        #endif
        try disableSIGPIPE()
    }

    private func disableSIGPIPE() throws {
        #if canImport(Darwin)
        var value: Int32 = 1
        guard setsockopt(rawValue, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketError.operationFailed("setsockopt(SO_NOSIGPIPE)")
        }
        #endif
    }

    private func bind(host: String, port: Int) throws {
        #if canImport(WinSDK)
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = UInt16(port).bigEndian

        if host == "0.0.0.0" {
            address.sin_addr.S_un.S_addr = INADDR_ANY
        } else if host == "localhost" {
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                throw SocketError.operationFailed("inet_pton")
            }
        } else {
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw SocketError.invalidRequest("Only IPv4 bind hosts are supported by AdaMCP HTTP server.")
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                WinSDK.bind(rawValue, sockaddrPointer, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        #else
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian

        if host == "0.0.0.0" {
            address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else if host == "localhost" {
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                throw SocketError.operationFailed("inet_pton")
            }
        } else {
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw SocketError.invalidRequest("Only IPv4 bind hosts are supported by AdaMCP HTTP server.")
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                DarwinBridge.bind(rawValue, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #endif
        guard result == 0 else {
            throw SocketError.operationFailed("bind")
        }
    }

    func boundPort() throws -> Int {
        #if canImport(WinSDK)
        var address = sockaddr_in()
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                WinSDK.getsockname(rawValue, sockaddrPointer, &length)
            }
        }
        guard result == 0 else {
            throw SocketError.operationFailed("getsockname")
        }
        return Int(UInt16(bigEndian: address.sin_port))
        #else
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                DarwinBridge.getsockname(rawValue, sockaddrPointer, &length)
            }
        }
        guard result == 0 else {
            throw SocketError.operationFailed("getsockname")
        }
        return Int(UInt16(bigEndian: address.sin_port))
        #endif
    }

    private func readChunk(into data: inout Data) throws {
        var buffer = [UInt8](repeating: 0, count: 8192)
        #if canImport(WinSDK)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            WinSDK.recv(rawValue, bytes.baseAddress, Int32(bytes.count), 0)
        }
        #else
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            DarwinBridge.recv(rawValue, bytes.baseAddress, bytes.count, 0)
        }
        #endif
        guard readCount > 0 else {
            throw SocketError.connectionClosed
        }
        data.append(buffer, count: Int(readCount))
    }

    private func writeHTTPHead(statusCode: Int, headers: [String: String]) throws {
        var text = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        try writeAll(Data(text.utf8))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            var sent = 0
            while sent < bytes.count {
                #if canImport(WinSDK)
                let count = WinSDK.send(rawValue, baseAddress.advanced(by: sent), Int32(bytes.count - sent), 0)
                #else
                let count = DarwinBridge.send(rawValue, baseAddress.advanced(by: sent), bytes.count - sent)
                #endif
                guard count > 0 else {
                    throw SocketError.connectionClosed
                }
                sent += Int(count)
            }
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        default: "HTTP Response"
        }
    }
}

private enum SocketError: LocalizedError {
    case connectionClosed
    case invalidRequest(String)
    case operationFailed(String)
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "Connection closed."
        case .invalidRequest(let message):
            message
        case .operationFailed(let operation):
            "\(operation) failed with errno \(errno)."
        case .unsupportedPlatform:
            "Embedded AdaMCP HTTP server is not supported on this platform."
        }
    }
}

#if canImport(WinSDK)
private enum WindowsSocketRuntime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var didStart = false

    static func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard didStart == false else {
            return
        }

        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else {
            throw SocketError.operationFailed("WSAStartup")
        }
        didStart = true
    }
}
#endif

#if canImport(Darwin) || canImport(Glibc)
private enum DarwinBridge {
    static func accept(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        #if canImport(Darwin)
        Darwin.accept(socket, address, length)
        #elseif canImport(Glibc)
        Glibc.accept(socket, address, length)
        #else
        -1
        #endif
    }

    static func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.bind(socket, address, length)
        #elseif canImport(Glibc)
        Glibc.bind(socket, address, length)
        #else
        -1
        #endif
    }

    static func close(_ socket: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(socket)
        #elseif canImport(Glibc)
        Glibc.close(socket)
        #else
        -1
        #endif
    }

    static func getsockname(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        #if canImport(Darwin)
        Darwin.getsockname(socket, address, length)
        #elseif canImport(Glibc)
        Glibc.getsockname(socket, address, length)
        #else
        -1
        #endif
    }

    static func recv(_ socket: Int32, _ buffer: UnsafeMutableRawPointer?, _ length: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        Darwin.recv(socket, buffer, length, flags)
        #elseif canImport(Glibc)
        Glibc.recv(socket, buffer, length, flags)
        #else
        -1
        #endif
    }

    static func send(_ socket: Int32, _ buffer: UnsafeRawPointer, _ length: Int) -> Int {
        #if canImport(Darwin)
        Darwin.send(socket, buffer, length, 0)
        #elseif canImport(Glibc)
        Glibc.send(socket, buffer, length, Int32(MSG_NOSIGNAL))
        #else
        -1
        #endif
    }
}
#endif
