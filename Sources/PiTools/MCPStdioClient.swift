import Foundation
import CoreFoundation
import PiTypes
import PiProviders
import PiAgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct MCPServerConfiguration: Codable, Sendable {
    public var transport: String
    public var command: String?
    public var url: String?
    public var args: [String]
    public var env: [String: String]
    public var headers: [String: String]

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.transport = "stdio"
        self.command = command
        self.url = nil
        self.args = args
        self.env = env
        self.headers = [:]
    }

    public init(url: URL, headers: [String: String] = [:]) {
        self.transport = "streamable-http"
        self.command = nil
        self.url = url.absoluteString
        self.args = []
        self.env = [:]
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey { case transport, command, url, args, env, headers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? (command == nil ? "streamable-http" : "stdio")
        args = try values.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try values.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

public struct MCPServerConfigFile: Codable, Sendable {
    public var servers: [String: MCPServerConfiguration]
    public init(servers: [String: MCPServerConfiguration]) { self.servers = servers }
}

/// Minimal MCP stdio client for initialize, tools/list, and tools/call.
/// Each client serializes requests so request IDs and stdio responses remain correlated.
public final class MCPStdioClient: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let lock = NSRecursiveLock()
    private var outputBuffer = Data()
    private var nextID = 1
    private let serverName: String
    private let responseTimeout: TimeInterval
    private var serverCapabilities: Set<String>
    private var notificationContinuations: [UUID: AsyncStream<MCPNotification>.Continuation] = [:]

    private init(serverName: String, process: Process, input: Pipe, output: Pipe,
                 responseTimeout: TimeInterval, serverCapabilities: Set<String>) {
        self.serverName = serverName
        self.process = process
        self.input = input
        self.output = output
        self.responseTimeout = responseTimeout
        self.serverCapabilities = serverCapabilities
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public static func connect(name: String, configuration: MCPServerConfiguration,
                               workingDirectory: URL? = nil, responseTimeout: TimeInterval = 30) throws -> MCPStdioClient {
        guard configuration.transport == "stdio", let command = configuration.command, !command.isEmpty else {
            throw MCPClientError.invalidResponse("MCP server '\(name)' is not configured for stdio")
        }
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = configuration.args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + configuration.args
        }
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.env) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()

        // Drain stderr independently so a verbose server cannot block on a full pipe.
        let errorHandle = errorPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { while !errorHandle.readData(ofLength: 4096).isEmpty {} }

        let client = MCPStdioClient(serverName: name, process: process, input: input, output: output,
                                    responseTimeout: responseTimeout, serverCapabilities: [])
        let initializeResult = try client.request(method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "apple-agent", "version": "0.2.0"]
        ])
        guard let negotiatedVersion = initializeResult["protocolVersion"] as? String,
              ["2025-03-26", "2025-06-18", "2025-11-25"].contains(negotiatedVersion) else {
            throw MCPClientError.unsupportedVersion(initializeResult["protocolVersion"] as? String ?? "missing")
        }
        let capabilities = Set((initializeResult["capabilities"] as? [String: Any] ?? [:]).keys)
        client.serverCapabilities = capabilities
        try client.notify(method: "notifications/initialized", params: [:])
        return client
    }

    public func agentTools() throws -> [AgentTool] {
        let result = try paginatedRequest(method: "tools/list", params: [:], collectionKey: "tools", identityKey: "name")
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw MCPClientError.invalidResponse("tools/list response has no tools array")
        }
        let client = self
        var adaptedTools = try tools.map { item in
            guard let originalName = item["name"] as? String, !originalName.isEmpty else {
                throw MCPClientError.invalidResponse("MCP tool has no name")
            }
            let prefixedName = "mcp_\(Self.safeIdentifier(serverName))_\(Self.safeIdentifier(originalName))"
            let description = item["description"] as? String ?? "MCP tool \(originalName) from \(serverName)"
            let schema = Self.jsonValue(from: item["inputSchema"] ?? ["type": "object"])
            return AgentTool(
                declaration: ToolDeclaration(name: prefixedName, description: description, inputSchema: schema),
                permission: .external
            ) { _, arguments, context in
                try await Task.detached {
                    let response = try client.request(method: "tools/call", params: [
                        "name": originalName,
                        "arguments": try JSONSerialization.jsonObject(with: arguments.encodedData)
                    ], cancellation: context.cancellation)
                    return Self.toolResult(from: response)
                }.value
            }
        }
        if serverCapabilities.contains("resources") {
            adaptedTools.append(AgentTool(
                declaration: ToolDeclaration(name: "mcp_\(Self.safeIdentifier(serverName))_resources_list",
                                             description: "List resources exposed by MCP server \(serverName)",
                                             inputSchema: Self.objectSchema([:])), permission: .external
            ) { _, _, context in try clientToolResult(client.listResources(cancellation: context.cancellation)) })
            adaptedTools.append(AgentTool(
                declaration: ToolDeclaration(name: "mcp_\(Self.safeIdentifier(serverName))_resources_read",
                                             description: "Read an MCP resource URI from server \(serverName)",
                                             inputSchema: Self.objectSchema(["uri": .object(["type": .string("string")])])),
                permission: .external
            ) { _, arguments, context in
                guard let uri = arguments.objectValue?["uri"]?.stringValue else {
                    throw MCPClientError.invalidResponse("resource URI is required")
                }
                return try clientToolResult(client.request(method: "resources/read", params: ["uri": uri], cancellation: context.cancellation))
            })
        }
        return adaptedTools
    }

    public func listPrompts() throws -> JSONValue {
        try clientValue(paginatedRequest(method: "prompts/list", params: [:], collectionKey: "prompts", identityKey: "name"))
    }

    public func getPrompt(name: String, arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        try clientValue(request(method: "prompts/get", params: ["name": name,
                           "arguments": arguments.mapValues(Self.foundationValue)]))
    }

    public func notifications() -> AsyncStream<MCPNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            lock.lock(); notificationContinuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.removeNotificationContinuation(id) }
        }
    }

    public var supportsPrompts: Bool { serverCapabilities.contains("prompts") }
    public var supportsResources: Bool { serverCapabilities.contains("resources") }

    public func listResources(cancellation: CancellationToken? = nil) throws -> JSONValue {
        try clientValue(paginatedRequest(method: "resources/list", params: [:], collectionKey: "resources", identityKey: "uri", cancellation: cancellation))
    }

    public func readResource(uri: String, cancellation: CancellationToken? = nil) throws -> JSONValue {
        try clientValue(request(method: "resources/read", params: ["uri": uri], cancellation: cancellation))
    }

    public func listResourceTemplates() throws -> JSONValue {
        try clientValue(paginatedRequest(method: "resources/templates/list", params: [:], collectionKey: "resourceTemplates", identityKey: "uriTemplate"))
    }

    private func paginatedRequest(method: String, params baseParams: [String: Any],
                                  collectionKey: String, identityKey: String,
                                  cancellation: CancellationToken? = nil) throws -> [String: Any] {
        var cursor: String?
        var seenCursors = Set<String>()
        var seenItems = Set<String>()
        var items: [[String: Any]] = []
        var combined: [String: Any] = [:]
        for _ in 0..<100 {
            var params = baseParams
            if let cursor { params["cursor"] = cursor }
            let page = try request(method: method, params: params, cancellation: cancellation)
            guard let pageItems = page[collectionKey] as? [[String: Any]] else {
                throw MCPClientError.invalidResponse("\(method) page has no \(collectionKey) array")
            }
            if combined.isEmpty { combined = page }
            for item in pageItems {
                let identity: String
                if let value = item[identityKey] as? String { identity = value }
                else if let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]),
                        let value = String(data: data, encoding: .utf8) { identity = value }
                else { identity = "" }
                if seenItems.insert(identity).inserted { items.append(item) }
                if items.count > 10_000 { throw MCPClientError.invalidResponse("\(method) exceeded the 10000 item limit") }
            }
            guard let next = page["nextCursor"] as? String, !next.isEmpty else {
                combined[collectionKey] = items
                combined.removeValue(forKey: "nextCursor")
                return combined
            }
            guard seenCursors.insert(next).inserted else {
                throw MCPClientError.invalidResponse("\(method) repeated a pagination cursor")
            }
            cursor = next
        }
        throw MCPClientError.invalidResponse("\(method) exceeded the 100 page limit")
    }

    private func request(method: String, params: [String: Any], cancellation: CancellationToken? = nil) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { throw MCPClientError.serverExited(serverName) }
        let id = nextID
        nextID += 1
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            if cancellation?.isCancelled == true || Task.isCancelled {
                try? write(["jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": ["requestId": id, "reason": "Client request cancelled"]])
                throw CancellationError()
            }
            let message: [String: Any]
            do { message = try readMessage(cancellation: cancellation) }
            catch is CancellationError {
                try? write(["jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": ["requestId": id, "reason": "Client request cancelled"]])
                throw CancellationError()
            }
            guard let responseID = message["id"] as? Int else {
                if let method = message["method"] as? String, method.hasPrefix("notifications/") {
                    let params = Self.jsonValue(from: message["params"] ?? [:])
                    let notification = MCPNotification(method: method, params: params)
                    notificationContinuations.values.forEach { $0.yield(notification) }
                }
                continue
            }
            guard responseID == id else { continue }
            guard message["jsonrpc"] as? String == "2.0" else {
                throw MCPClientError.invalidResponse("MCP response must use JSON-RPC 2.0")
            }
            if let error = message["error"] as? [String: Any] {
                throw MCPClientError.remoteError(error["code"] as? Int ?? -1,
                                                 error["message"] as? String ?? "MCP request failed")
            }
            guard let result = message["result"] as? [String: Any] else {
                throw MCPClientError.invalidResponse("MCP response for \(method) has no result")
            }
            return result
        }
    }

    private func notify(method: String, params: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func removeNotificationContinuation(_ id: UUID) {
        lock.lock(); notificationContinuations.removeValue(forKey: id); lock.unlock()
    }

    private func write(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .fragmentsAllowed])
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readMessage(cancellation: CancellationToken? = nil) throws -> [String: Any] {
        let handle = output.fileHandleForReading
        let deadline = Date().addingTimeInterval(responseTimeout)
        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer.prefix(upTo: newline)
                outputBuffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw MCPClientError.invalidResponse("MCP server wrote a non-object stdio record")
                }
                return object
            }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw MCPClientError.timeout(serverName, responseTimeout) }
            let remainingMilliseconds = max(1, min(remaining * 1_000, Double(Int32.max)))
            let milliseconds = Int32(cancellation == nil ? remainingMilliseconds : min(remainingMilliseconds, 100))
            let ready = poll(&descriptor, nfds_t(1), milliseconds)
            if ready <= 0, cancellation?.isCancelled == true { throw CancellationError() }
            if ready == 0 { continue }
            guard ready > 0 else { throw MCPClientError.timeout(serverName, responseTimeout) }
            let chunk = handle.readData(ofLength: 1)
            guard !chunk.isEmpty else { throw MCPClientError.serverExited(serverName) }
            outputBuffer.append(chunk)
        }
    }

    private static func toolResult(from response: [String: Any]) -> ToolResult {
        let content = response["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        let isError = response["isError"] as? Bool ?? false
        return ToolResult(text: text.isEmpty ? "MCP tool returned no text content" : text,
                          details: .object(["content": .array(content.map { jsonValue(from: $0) })]), isError: isError)
    }

    private static func jsonValue(from value: Any) -> JSONValue {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        if let value = value as? [String: Any] { return .object(value.mapValues(jsonValue(from:))) }
        if let value = value as? [Any] { return .array(value.map(jsonValue(from:))) }
        return .null
    }

    private static func safeIdentifier(_ value: String) -> String {
        let result = value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return String(result)
    }

    private static func objectSchema(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .object(let values): values.mapValues(foundationValue)
        case .array(let values): values.map(foundationValue)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }
}

private func clientToolResult(_ value: [String: Any]) throws -> ToolResult {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    let json = decodeJSONValue(value)
    return ToolResult(text: String(data: data, encoding: .utf8) ?? "{}", details: json,
                      isError: value["isError"] as? Bool ?? false)
}

private func clientValue(_ value: [String: Any]) throws -> JSONValue {
    decodeJSONValue(value)
}

private func decodeJSONValue(_ value: Any) -> JSONValue {
    if value is NSNull { return .null }
    if let value = value as? String { return .string(value) }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
        return .number(value.doubleValue)
    }
    if let value = value as? [String: Any] { return .object(value.mapValues(decodeJSONValue)) }
    if let value = value as? [Any] { return .array(value.map(decodeJSONValue)) }
    return .null
}

public enum MCPClientError: Error, LocalizedError {
    case serverExited(String)
    case invalidResponse(String)
    case remoteError(Int, String)
    case timeout(String, TimeInterval)
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .serverExited(let name): "MCP server '\(name)' exited or closed its output"
        case .invalidResponse(let message): message
        case .remoteError(let code, let message): "MCP error \(code): \(message)"
        case .timeout(let name, let duration): "MCP server '\(name)' did not respond within \(Int(duration)) seconds"
        case .unsupportedVersion(let version): "MCP server negotiated unsupported protocol version '\(version)'"
        }
    }
}

private func clientToolResult(_ value: JSONValue) -> ToolResult {
    ToolResult(text: String(data: value.encodedData, encoding: .utf8) ?? "{}", details: value,
               isError: value.objectValue?["isError"]?.boolValue ?? false)
}
