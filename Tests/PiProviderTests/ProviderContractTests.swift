import Foundation
import XCTest
import PiTypes
import PiProviders

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()
    private var storedRequest: URLRequest?
    func configure(data: Data) { lock.lock(); storedData = data; storedRequest = nil; lock.unlock() }
    func snapshot() -> (Data, URLRequest?) { lock.lock(); defer { lock.unlock() }; return (storedData, storedRequest) }
    func record(_ request: URLRequest) { lock.lock(); storedRequest = request; lock.unlock() }
}

private final class StubURLProtocol: URLProtocol {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        let (data, _) = Self.state.snapshot()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct CatalogFixture: ModelCatalogSource {
    let catalogProviderID: String
    let models: [ModelDescriptor]
    let shouldFail: Bool
    func fetchModels() async throws -> [ModelDescriptor] {
        if shouldFail { throw ProviderFailure("offline", "offline") }
        return models
    }
}

final class ProviderContractTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testOpenAICompatibleSSEEmitsTextToolDeltasAndUsage() async throws {
        let body = """
        data: {"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"echo","arguments":"{\\"value\\":"}}]},"finish_reason":null}]}
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"ok\\"}"}}]},"finish_reason":"tool_calls"}]}
        data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}
        data: [DONE]

        """
        StubURLProtocol.state.configure(data: Data(body.utf8))
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "https://unit.test/v1")!, apiKey: "test-secret", session: session())
        let request = ModelRequest(model: ModelDescriptor(id: "fixture", providerID: "openai"), messages: [ConversationMessage(role: .user, text: "go")], tools: [])
        var events: [ModelStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        let deltas = events.compactMap { event -> String? in if case .textDelta(let value) = event { return value }; return nil }
        let toolDeltas = events.compactMap { event -> String? in if case .toolCallDelta(_, _, let name, _) = event { return name }; return nil }
        let turn = try XCTUnwrap(events.compactMap { event -> AssistantTurn? in if case .completed(let turn) = event { return turn }; return nil }.first)
        XCTAssertEqual(deltas, ["Hello"])
        XCTAssertEqual(toolDeltas, ["echo"])
        XCTAssertEqual(turn.toolCalls.first?.arguments.objectValue?["value"]?.stringValue, "ok")
        XCTAssertEqual(turn.usage, TokenUsage(inputTokens: 4, outputTokens: 2))
        let captured = StubURLProtocol.state.snapshot().1
        XCTAssertEqual(captured?.url?.path, "/v1/chat/completions")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
    }

    func testAnthropicMessagesSSEEmitsTextAndUsage() async throws {
        let body = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        StubURLProtocol.state.configure(data: Data(body.utf8))
        let provider = AnthropicProvider(apiKey: "test-secret", session: session())
        let request = ModelRequest(model: ModelDescriptor(id: "fixture", providerID: "anthropic"), messages: [ConversationMessage(role: .user, text: "go")], tools: [])
        var events: [ModelStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        XCTAssertTrue(events.contains { if case .textDelta("Hi") = $0 { return true }; return false })
        let turn = try XCTUnwrap(events.compactMap { event -> AssistantTurn? in if case .completed(let turn) = event { return turn }; return nil }.first)
        XCTAssertEqual(turn.text, "Hi")
        XCTAssertEqual(turn.stopReason, .stop)
        XCTAssertEqual(turn.usage, TokenUsage(inputTokens: 3, outputTokens: 1))
        let captured = StubURLProtocol.state.snapshot().1
        XCTAssertEqual(captured?.url?.path, "/v1/messages")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-api-key"), "test-secret")
    }

    func testGeminiSSEMapsTextFunctionCallsAndUsage() async throws {
        let body = #"""
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]}}]}

        data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"echo","args":{"value":"ok"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3}}

        """#
        StubURLProtocol.state.configure(data: Data(body.utf8))
        let provider = GoogleGeminiProvider(apiKey: "gemini-secret", session: session())
        let request = ModelRequest(model: ModelDescriptor(id: "gemini-test", providerID: "gemini"),
                                   messages: [ConversationMessage(role: .user, text: "go")], tools: [])
        var events: [ModelStreamEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        let turn = try XCTUnwrap(events.compactMap { event -> AssistantTurn? in
            if case .completed(let turn) = event { return turn }; return nil
        }.first)
        XCTAssertEqual(turn.text, "Hello")
        XCTAssertEqual(turn.toolCalls.first?.name, "echo")
        XCTAssertEqual(turn.toolCalls.first?.arguments.objectValue?["value"]?.stringValue, "ok")
        XCTAssertEqual(turn.usage, TokenUsage(inputTokens: 7, outputTokens: 3))
        let captured = StubURLProtocol.state.snapshot().1
        XCTAssertEqual(captured?.url?.path, "/v1beta/models/gemini-test:streamGenerateContent")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-secret")
    }

    func testModelCatalogReturnsStaleCacheWhenRefreshFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = ModelCatalog(directory: directory, timeToLive: 10)
        let date = Date(timeIntervalSince1970: 1_000)
        let model = ModelDescriptor(id: "cached-model", providerID: "fixture", contextWindow: 20_000)
        _ = try await catalog.models(from: CatalogFixture(catalogProviderID: "fixture", models: [model], shouldFail: false), now: date)
        let offline = try await catalog.models(from: CatalogFixture(catalogProviderID: "fixture", models: [], shouldFail: true),
                                               forceRefresh: true, now: date.addingTimeInterval(20))
        XCTAssertTrue(offline.isStale)
        XCTAssertEqual(offline.models, [model])
    }
    func testModelDescriptorDecodesLegacyCatalogWithUnknownCapabilities() throws {
        let data = Data("{\"id\":\"legacy\",\"providerID\":\"fixture\"}".utf8)
        let model = try JSONDecoder().decode(ModelDescriptor.self, from: data)
        XCTAssertNil(model.supportsTools)
        XCTAssertNil(model.imageInput)
        XCTAssertNil(model.reasoning)
        XCTAssertNil(model.streaming)
    }

}
