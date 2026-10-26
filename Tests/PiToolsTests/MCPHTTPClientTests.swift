import Foundation
import XCTest
import PiTypes
import PiAgentCore
@testable import PiTools

final class MCPHTTPClientTests: XCTestCase {
    func testInitializesDiscoversAndCallsToolOverStreamableHTTP() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = URL(string: "https://mcp.example.test/mcp")!
        let client = try await MCPStreamableHTTPClient.connect(name: "remote", endpoint: endpoint, session: session)
        var notifications = await client.notifications().makeAsyncIterator()
        let tools = try await client.agentTools()
        XCTAssertEqual(Array(tools.prefix(2)).map(\.declaration.name), ["mcp_remote_echo", "mcp_remote_echo_second"])
        XCTAssertTrue(tools.contains { $0.declaration.name == "mcp_remote_resources_list" })
        let context = ToolContext(workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true), cancellation: CancellationToken())
        let result = try await tools[0].execute("test-call", .object(["value": .string("hi")]), context)
        XCTAssertEqual(result.text, "http fixture result")
        XCTAssertFalse(result.isError)
        let resources = try await client.listResources()
        XCTAssertEqual(resources.objectValue?["resources"]?.arrayValue?.count, 2)
        let notification = await notifications.next()
        XCTAssertEqual(notification?.method, "notifications/tools/list_changed")
    }

    func testCancelledRequestSendsMCPNotification() async throws {
        MCPFixtureURLProtocol.resetCancellationIDs()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try await MCPStreamableHTTPClient.connect(name: "remote", endpoint: URL(string: "https://mcp.example.test/mcp")!, session: session)
        let tools = try await client.agentTools()
        let context = ToolContext(workingDirectory: URL(fileURLWithPath: "/tmp"), cancellation: CancellationToken())
        let task = Task { try await tools[0].execute("slow-call", .object(["slow": .bool(true)]), context) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled MCP call should throw") }
        catch is CancellationError {}
        for _ in 0..<20 where MCPFixtureURLProtocol.cancellationIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(MCPFixtureURLProtocol.cancellationIDs.isEmpty)
    }

    func testServerInitiatedNotificationSSEFrameParsingAndGETSubscription() async throws {
        let frame = MCPHTTPEventStreamParser.notification(dataLines: [
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{}}"
        ])
        XCTAssertEqual(frame?.method, "notifications/tools/list_changed")
        XCTAssertNil(MCPHTTPEventStreamParser.notification(dataLines: [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        ]))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = URL(string: "https://mcp.example.test/mcp?event-stream")!
        let client = try await MCPStreamableHTTPClient.connect(name: "remote", endpoint: endpoint, session: session)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThanOrEqual(MCPFixtureURLProtocol.getRequests, 1)
        await client.close()
    }
}

private final class MCPFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let cancellationState = CancellationState()
    private static let getRequestState = CancellationState()
    static var getRequests: Int { getRequestState.values.count }
    private let loadingLock = NSLock()
    private var stopped = false
    static var cancellationIDs: [Int] { cancellationState.values }
    static func resetCancellationIDs() { cancellationState.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        if request.httpMethod == "GET" {
            Self.getRequestState.append(1)
            if request.value(forHTTPHeaderField: "Last-Event-ID") == nil,
               request.url?.query == "event-stream" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "text/event-stream"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let event = Data("id: event-1\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{}}\n\n".utf8)
                client?.urlProtocol(self, didLoad: event)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if method == "notifications/cancelled" {
            let params = message["params"] as? [String: Any] ?? [:]
            if let requestID = params["requestId"] as? Int {
                Self.cancellationState.append(requestID)
            }
            respond(with: ["jsonrpc": "2.0", "result": [:]])
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        if method == "tools/call", arguments["slow"] as? Bool == true {
            let responseID = id as? Int ?? 0
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self, responseID] in
                self?.respond(with: ["jsonrpc": "2.0", "id": responseID, "result": [:]])
            }
            return
        }
        let result: [String: Any]
        if method == "tools/list" {
            let params = message["params"] as? [String: Any] ?? [:]
            if params["cursor"] as? String == "page-2" {
                result = ["tools": [["name": "echo_second", "description": "Second page", "inputSchema": ["type": "object"]]]]
            } else {
                result = ["tools": [["name": "echo", "description": "Echo", "inputSchema": ["type": "object"]]], "nextCursor": "page-2"]
            }
        } else {
            result = responseResult(method: method, message: message)
        }
        var responseObject: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { responseObject["id"] = id }
        let data = (try? JSONSerialization.data(withJSONObject: responseObject)) ?? Data()
        let responseBody: Data
        let contentType: String
        if method == "tools/list" {
            let notification = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{}}\n\n".utf8)
            responseBody = notification + Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":-1,\"result\":{}}\n\nevent: message\ndata: ".utf8) + data + Data("\n\n".utf8)
            contentType = "text/event-stream"
        } else {
            responseBody = data
            contentType = "application/json"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType, "Mcp-Session-Id": "fixture-session"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseBody.isEmpty { client?.urlProtocol(self, didLoad: responseBody) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(with object: [String: Any]) {
        loadingLock.lock(); let shouldRespond = !stopped; loadingLock.unlock()
        guard shouldRespond else { return }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func responseResult(method: String, message: [String: Any]) -> [String: Any] {
        switch method {
        case "initialize": return ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:], "resources": [:]], "serverInfo": ["name": "fixture", "version": "1"]]
        case "resources/list":
            let params = message["params"] as? [String: Any] ?? [:]
            if params["cursor"] as? String == "resource-page-2" { return ["resources": [["uri": "file:///second", "name": "second"]]] }
            return ["resources": [["uri": "file:///first", "name": "first"]], "nextCursor": "resource-page-2"]
        case "tools/call": return ["content": [["type": "text", "text": "http fixture result"]], "isError": false]
        default: return [:]
        }
    }

    override func stopLoading() { loadingLock.lock(); stopped = true; loadingLock.unlock() }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int] = []
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storedValues }
    func append(_ value: Int) { lock.lock(); storedValues.append(value); lock.unlock() }
    func reset() { lock.lock(); storedValues = []; lock.unlock() }
}
