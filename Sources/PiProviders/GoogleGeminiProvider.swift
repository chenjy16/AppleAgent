import Foundation
import PiTypes
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleGeminiProvider: ModelProvider, ModelCatalogSource {
    public let id = "gemini"
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public var catalogProviderID: String { id }
    public var capabilities: ProviderCapabilities { ProviderCapabilities(imageInput: false, contextWindow: nil) }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(url: baseURL.appendingPathComponent("models/\(request.model.id):streamGenerateContent"), resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
                    var urlRequest = URLRequest(url: components.url!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try Self.makeBody(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw ProviderFailure("invalid_response", "Expected HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n"; if body.count > 8_000 { break } }
                        throw ProviderFailure("http_\(http.statusCode)", body.trimmingCharacters(in: .whitespacesAndNewlines),
                                              statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-goog-request-id"))
                    }
                    var text = ""
                    var calls: [Int: GeminiFunctionCall] = [:]
                    var usage: TokenUsage?
                    var reason: StopReason = .unknown
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:"),
                              let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let metadata = root["usageMetadata"] as? [String: Any] {
                            usage = TokenUsage(inputTokens: metadata["promptTokenCount"] as? Int ?? 0,
                                               outputTokens: metadata["candidatesTokenCount"] as? Int ?? 0)
                            if let usage { continuation.yield(.usage(usage)) }
                        }
                        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { continue }
                        if let finishReason = candidate["finishReason"] as? String {
                            reason = finishReason == "MAX_TOKENS" ? .length : .stop
                        }
                        guard let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { continue }
                        for (index, part) in parts.enumerated() {
                            if let fragment = part["text"] as? String, !fragment.isEmpty {
                                text += fragment
                                continuation.yield(.textDelta(fragment))
                            }
                            if let function = part["functionCall"] as? [String: Any], let name = function["name"] as? String {
                                let args = function["args"] as? [String: Any] ?? [:]
                                let json = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .fragmentsAllowed])
                                calls[index] = GeminiFunctionCall(id: UUID().uuidString, name: name, arguments: String(decoding: json, as: UTF8.self))
                            }
                        }
                    }
                    let toolCalls = try calls.keys.sorted().compactMap { index -> ToolCall? in
                        guard let call = calls[index] else { return nil }
                        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))
                        return ToolCall(id: call.id, name: call.name, arguments: arguments)
                    }
                    if !toolCalls.isEmpty { reason = .toolUse }
                    continuation.yield(.completed(AssistantTurn(text: text, toolCalls: toolCalls, stopReason: reason, usage: usage)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderFailure("aborted", "Request cancelled"))
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fetchModels() async throws -> [ModelDescriptor] {
        var pageToken: String?
        var models: [ModelDescriptor] = []
        for _ in 0..<20 {
            var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderFailure("invalid_response", "Expected HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw ProviderFailure("http_\(http.statusCode)", String(decoding: data.prefix(8_000), as: UTF8.self),
                                      statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-goog-request-id"))
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["models"] as? [[String: Any]] else {
                throw ProviderFailure("invalid_response", "Gemini model catalog response has no models array")
            }
            models.append(contentsOf: items.compactMap { item in
                guard let fullName = item["name"] as? String else { return nil }
                let id = fullName.hasPrefix("models/") ? String(fullName.dropFirst("models/".count)) : fullName
                let methods = item["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { return nil }
                return ModelDescriptor(id: id, providerID: self.id, contextWindow: item["inputTokenLimit"] as? Int,
                                       supportsTools: true)
            })
            guard let next = root["nextPageToken"] as? String, !next.isEmpty, next != pageToken else { break }
            pageToken = next
        }
        return models
    }

    private static func makeBody(_ request: ModelRequest) throws -> Data {
        var systemParts: [[String: Any]] = []
        var contents: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system: systemParts.append(["text": message.text])
            case .user, .custom: contents.append(["role": "user", "parts": [["text": message.text]]])
            case .assistant:
                var parts: [[String: Any]] = []
                if !message.text.isEmpty { parts.append(["text": message.text]) }
                parts += message.toolCalls.map { ["functionCall": ["name": $0.name, "args": foundationValue($0.arguments)]] as [String: Any] }
                contents.append(["role": "model", "parts": parts])
            case .toolResult:
                let result: [String: Any] = ["functionResponse": ["name": message.toolName ?? "tool", "response": ["content": message.text]]]
                contents.append(["role": "user", "parts": [result]])
            }
        }
        var body: [String: Any] = ["contents": contents]
        if !systemParts.isEmpty { body["systemInstruction"] = ["parts": systemParts] }
        if let temperature = request.temperature { body["generationConfig"] = ["temperature": temperature] }
        if !request.tools.isEmpty {
            body["tools"] = [["functionDeclarations": request.tools.map { tool in
                ["name": tool.name, "description": tool.description, "parameters": foundationValue(tool.inputSchema)] as [String: Any]
            }]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .object(let object): object.mapValues(foundationValue)
        case .array(let array): array.map(foundationValue)
        case .string(let string): string
        case .number(let number): number
        case .bool(let bool): bool
        case .null: NSNull()
        }
    }
}

private struct GeminiFunctionCall {
    var id: String
    var name: String
    var arguments: String
}
