import Foundation
import PiTypes
import PiProviders
import PiAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MCPNotification: Sendable, Equatable {
    public var method: String
    public var params: JSONValue
    public init(method: String, params: JSONValue) { self.method = method; self.params = params }
}


enum MCPHTTPEventStreamParser {
    static func notification(dataLines: [String]) -> MCPNotification? {
        let data = Data(dataLines.joined(separator: "\n").utf8)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let fields = value.objectValue,
              fields["id"] == nil,
              let method = fields["method"]?.stringValue,
              method.hasPrefix("notifications/") else { return nil }
        return MCPNotification(method: method, params: fields["params"] ?? .object([:]))
    }
}

private actor MCPNotificationHub {
    private var continuations: [UUID: AsyncStream<MCPNotification>.Continuation] = [:]
    private var buffered: [MCPNotification] = []

    func stream() -> AsyncStream<MCPNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            continuations[id] = continuation
            for notification in buffered { continuation.yield(notification) }
            buffered.removeAll(keepingCapacity: true)
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }

    func publish(_ notification: MCPNotification) {
        if continuations.isEmpty {
            buffered.append(notification)
            if buffered.count > 128 { buffered.removeFirst(buffered.count - 128) }
        } else {
            continuations.values.forEach { $0.yield(notification) }
        }
    }

    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
}

private actor MCPHTTPEventStreamRunner {
    private let endpoint: URL
    private let headers: [String: String]
    private let protocolVersion: String
    private let sessionID: String?
    private let session: URLSession
    private let hub: MCPNotificationHub
    private var lastEventID: String?
    private var retryMilliseconds = 1_000

    init(endpoint: URL, headers: [String: String], protocolVersion: String, sessionID: String?,
         session: URLSession, hub: MCPNotificationHub) {
        self.endpoint = endpoint; self.headers = headers; self.protocolVersion = protocolVersion
        self.sessionID = sessionID; self.session = session; self.hub = hub
    }

    func run() async {
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 86_400)
                request.httpMethod = "GET"
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
                if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
                if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 405 || http.statusCode == 401 || http.statusCode == 403 { return }
                guard (200..<300).contains(http.statusCode),
                      http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                    return
                }
                var dataLines: [String] = []
                var frameID: String?
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    if line.isEmpty {
                        if let frameID { lastEventID = frameID }
                        if let notification = MCPHTTPEventStreamParser.notification(dataLines: dataLines) {
                            await hub.publish(notification)
                        }
                        dataLines.removeAll(keepingCapacity: true)
                        frameID = nil
                        continue
                    }
                    if line.hasPrefix(":") { continue }
                    let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    let field = String(pieces[0])
                    var value = pieces.count > 1 ? String(pieces[1]) : ""
                    if value.first == " " { value.removeFirst() }
                    switch field {
                    case "data": dataLines.append(value)
                    case "id": if !value.contains("\0") { frameID = value }
                    case "retry": if let retry = Int(value) { retryMilliseconds = min(30_000, max(250, retry)) }
                    default: break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
            do { try await Task.sleep(for: .milliseconds(retryMilliseconds)) }
            catch { return }
        }
    }
}

/// MCP Streamable HTTP client for a single server endpoint/session.
public actor MCPStreamableHTTPClient {
    private let name: String
    private let endpoint: URL
    private let headers: [String: String]
    private let session: URLSession
    private let timeout: TimeInterval
    private var protocolVersion = "2025-11-25"
    private var sessionID: String?
    private var nextID = 1
    private var capabilities: Set<String> = []
    private let notificationHub = MCPNotificationHub()
    private var eventStreamTask: Task<Void, Never>?

    private init(name: String, endpoint: URL, headers: [String: String], session: URLSession, timeout: TimeInterval) {
        self.name = name
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
        self.timeout = timeout
    }

    public static func connect(name: String, endpoint: URL, headers: [String: String] = [:],
                               session: URLSession = .shared, timeout: TimeInterval = 30) async throws -> MCPStreamableHTTPClient {
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(endpoint.host ?? "")) else {
            throw MCPClientError.invalidResponse("MCP HTTP endpoint must use HTTPS (HTTP is allowed only for localhost)")
        }
        let client = MCPStreamableHTTPClient(name: name, endpoint: endpoint, headers: headers, session: session, timeout: timeout)
        let result = try await client.request(method: "initialize", params: .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("apple-agent"), "version": .string("0.2.0")])
        ]))
        guard let version = result.objectValue?["protocolVersion"]?.stringValue,
              ["2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else {
            throw MCPClientError.unsupportedVersion(result.objectValue?["protocolVersion"]?.stringValue ?? "missing")
        }
        await client.configure(protocolVersion: version,
                               capabilities: Set(result.objectValue?["capabilities"]?.objectValue?.keys ?? Dictionary<String, JSONValue>().keys))
        try await client.notify(method: "notifications/initialized", params: .object([:]))
        await client.startEventStream()
        return client
    }

    public func agentTools() async throws -> [AgentTool] {
        let result = try await paginatedRequest(method: "tools/list", collectionKey: "tools", identityKey: "name")
        guard let items = result.objectValue?["tools"]?.arrayValue else {
            throw MCPClientError.invalidResponse("tools/list response has no tools array")
        }
        var tools = try items.map { item -> AgentTool in
            guard let fields = item.objectValue, let originalName = fields["name"]?.stringValue, !originalName.isEmpty else {
                throw MCPClientError.invalidResponse("MCP tool has no name")
            }
            let safeServer = Self.safeIdentifier(name)
            let safeTool = Self.safeIdentifier(originalName)
            let schema = fields["inputSchema"] ?? .object(["type": .string("object")])
            let description = fields["description"]?.stringValue ?? "MCP tool \(originalName) from \(name)"
            return AgentTool(declaration: ToolDeclaration(name: "mcp_\(safeServer)_\(safeTool)", description: description, inputSchema: schema),
                             permission: .external) { _, arguments, _ in
                let response = try await self.request(method: "tools/call", params: .object(["name": .string(originalName), "arguments": arguments]))
                return Self.toolResult(from: response)
            }
        }
        if capabilities.contains("resources") {
            let safeServer = Self.safeIdentifier(name)
            tools.append(AgentTool(declaration: ToolDeclaration(name: "mcp_\(safeServer)_resources_list",
                                    description: "List resources exposed by MCP server \(name)", inputSchema: Self.objectSchema([:])),
                                   permission: .external) { _, _, _ in
                let resources = try await self.listResources()
                return try Self.jsonToolResult(resources)
            })
            tools.append(AgentTool(declaration: ToolDeclaration(name: "mcp_\(safeServer)_resources_read",
                                    description: "Read an MCP resource URI from server \(name)",
                                    inputSchema: Self.objectSchema(["uri": .object(["type": .string("string")])])),
                                   permission: .external) { _, arguments, _ in
                guard let uri = arguments.objectValue?["uri"]?.stringValue else {
                    throw MCPClientError.invalidResponse("resource URI is required")
                }
                return try await Self.jsonToolResult(self.request(method: "resources/read", params: .object(["uri": .string(uri)])))
            })
        }
        return tools
    }

    public func listResources() async throws -> JSONValue {
        try await paginatedRequest(method: "resources/list", collectionKey: "resources", identityKey: "uri")
    }
    public func notifications() async -> AsyncStream<MCPNotification> { await notificationHub.stream() }
    public func listResourceTemplates() async throws -> JSONValue {
        try await paginatedRequest(method: "resources/templates/list", collectionKey: "resourceTemplates", identityKey: "uriTemplate")
    }
    public func readResource(uri: String) async throws -> JSONValue { try await request(method: "resources/read", params: .object(["uri": .string(uri)])) }
    public func listPrompts() async throws -> JSONValue {
        try await paginatedRequest(method: "prompts/list", collectionKey: "prompts", identityKey: "name")
    }
    public func getPrompt(name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await request(method: "prompts/get", params: .object(["name": .string(name), "arguments": .object(arguments)]))
    }

    public func close() async {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        guard let sessionID else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "DELETE"
        applyHeaders(to: &request)
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await session.data(for: request)
        self.sessionID = nil
    }

    private func paginatedRequest(method: String, collectionKey: String, identityKey: String) async throws -> JSONValue {
        var cursor: String?
        var seenCursors = Set<String>()
        var seenItems = Set<String>()
        var items: [JSONValue] = []
        var combined: [String: JSONValue] = [:]
        for _ in 0..<100 {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request(method: method, params: .object(params))
            guard let fields = page.objectValue, let pageItems = fields[collectionKey]?.arrayValue else {
                throw MCPClientError.invalidResponse("\(method) page has no \(collectionKey) array")
            }
            if combined.isEmpty { combined = fields }
            for item in pageItems {
                let identity = item.objectValue?[identityKey]?.stringValue
                    ?? String(data: item.encodedData, encoding: .utf8) ?? ""
                if seenItems.insert(identity).inserted { items.append(item) }
                if items.count > 10_000 { throw MCPClientError.invalidResponse("\(method) exceeded the 10000 item limit") }
            }
            guard let next = fields["nextCursor"]?.stringValue, !next.isEmpty else {
                combined[collectionKey] = .array(items)
                combined.removeValue(forKey: "nextCursor")
                return .object(combined)
            }
            guard seenCursors.insert(next).inserted else {
                throw MCPClientError.invalidResponse("\(method) repeated a pagination cursor")
            }
            cursor = next
        }
        throw MCPClientError.invalidResponse("\(method) exceeded the 100 page limit")
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                        "method": .string(method), "params": params])
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = message.encodedData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                sendCancellationNotification(requestID: id)
                throw CancellationError()
            }
            throw error
        }
        await consumeNotifications(in: data, contentType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
        guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse("Expected HTTP response") }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = value }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPClientError.remoteError(http.statusCode, String(decoding: data.prefix(8_000), as: UTF8.self))
        }
        guard let message = Self.decodeResponse(data, contentType: http.value(forHTTPHeaderField: "Content-Type"), expectedID: Double(id)),
              message.objectValue?["jsonrpc"]?.stringValue == "2.0",
              message.objectValue?["id"]?.numberValue == Double(id) else {
            throw MCPClientError.invalidResponse("MCP HTTP response did not contain the matching JSON-RPC response")
        }
        let fields = message.objectValue ?? [:]
        if let error = fields["error"]?.objectValue {
            throw MCPClientError.remoteError(Int(error["code"]?.numberValue ?? -1), error["message"]?.stringValue ?? "MCP request failed")
        }
        guard let result = fields["result"]?.objectValue else {
            throw MCPClientError.invalidResponse("MCP response for \(method) has no result")
        }
        return .object(result)
    }

    private func configure(protocolVersion: String, capabilities: Set<String>) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

    private func startEventStream() {
        guard eventStreamTask == nil else { return }
        let runner = MCPHTTPEventStreamRunner(endpoint: endpoint, headers: headers, protocolVersion: protocolVersion,
                                              sessionID: sessionID, session: session, hub: notificationHub)
        eventStreamTask = Task { await runner.run() }
    }

    public func supportsPrompts() -> Bool { capabilities.contains("prompts") }
    public func supportsResources() -> Bool { capabilities.contains("resources") }

    private func consumeNotifications(in data: Data, contentType: String?) async {
        guard contentType?.lowercased().contains("text/event-stream") == true else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let fields = value.objectValue,
                  fields["id"] == nil,
                  let method = fields["method"]?.stringValue,
                  method.hasPrefix("notifications/") else { continue }
            let notification = MCPNotification(method: method, params: fields["params"] ?? .object([:]))
            await notificationHub.publish(notification)
        }
    }

    private func sendCancellationNotification(requestID: Int) {
        let endpoint = self.endpoint
        let headers = self.headers
        let protocolVersion = self.protocolVersion
        let sessionID = self.sessionID
        let session = self.session
        let payload = JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(Double(requestID)), "reason": .string("Client request cancelled")])
        ]).encodedData
        Task.detached {
            var request = URLRequest(url: endpoint, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = payload
            _ = try? await session.data(for: request)
        }
    }

    private func notify(method: String, params: JSONValue) async throws {
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = message.encodedData
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPClientError.invalidResponse("MCP initialized notification was rejected")
        }
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    }

    private static func decodeResponse(_ data: Data, contentType: String?, expectedID: Double) -> JSONValue? {
        if contentType?.lowercased().contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let json = payload.data(using: .utf8),
                      let message = try? JSONDecoder().decode(JSONValue.self, from: json) else { continue }
                if message.objectValue?["id"]?.numberValue == expectedID { return message }
            }
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func toolResult(from response: JSONValue) -> ToolResult {
        let object = response.objectValue ?? [:]
        let blocks = object["content"]?.arrayValue ?? []
        let text = blocks.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        return ToolResult(text: text.isEmpty ? "MCP tool returned no text content" : text, details: response,
                          isError: object["isError"]?.boolValue ?? false)
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

    private static func objectSchema(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    private static func jsonToolResult(_ response: JSONValue) throws -> ToolResult {
        ToolResult(text: String(data: response.encodedData, encoding: .utf8) ?? "{}", details: response,
                   isError: response.objectValue?["isError"]?.boolValue ?? false)
    }

    private static func safeIdentifier(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }
}
