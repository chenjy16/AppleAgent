import Foundation
import PiTypes
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnthropicProvider: ModelProvider, ModelCatalogSource {
    public let id = "anthropic"
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!, session: URLSession = .shared) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.session = session
    }

    public var catalogProviderID: String { id }

    public func fetchModels() async throws -> [ModelDescriptor] {
        var models: [ModelDescriptor] = []
        var afterID: String?
        for _ in 0..<20 {
            var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { components.queryItems?.append(URLQueryItem(name: "after_id", value: afterID)) }
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderFailure("invalid_response", "Expected HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw ProviderFailure("http_\(http.statusCode)", String(decoding: data.prefix(8_000), as: UTF8.self),
                                      statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "request-id"))
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["data"] as? [[String: Any]] else {
                throw ProviderFailure("invalid_response", "Model catalog response has no data array")
            }
            models.append(contentsOf: items.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return ModelDescriptor(id: id, providerID: self.id)
            })
            guard root["has_more"] as? Bool == true,
                  let last = root["last_id"] as? String, last != afterID else { break }
            afterID = last
        }
        return models
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try Self.makeBody(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw ProviderFailure("invalid_response", "Expected HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n"; if body.count > 8_000 { break } }
                        throw ProviderFailure("http_\(http.statusCode)", body.trimmingCharacters(in: .whitespacesAndNewlines),
                                              statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "request-id"))
                    }
                    var text = ""
                    var usage = TokenUsage()
                    var stop: StopReason = .unknown
                    var tools: [Int: AnthropicToolAccumulator] = [:]
                    var currentEvent = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.hasPrefix("event:") { currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:"), let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        switch currentEvent {
                        case "message_start":
                            if let message = root["message"] as? [String: Any], let raw = message["usage"] as? [String: Any] {
                                usage.inputTokens = raw["input_tokens"] as? Int ?? 0
                                continuation.yield(.usage(usage))
                            }
                        case "content_block_start":
                            if let block = root["content_block"] as? [String: Any], (block["type"] as? String) == "tool_use" {
                                let index = root["index"] as? Int ?? 0
                                let id = block["id"] as? String ?? UUID().uuidString
                                let name = block["name"] as? String ?? ""
                                tools[index] = AnthropicToolAccumulator(id: id, name: name, input: "")
                                continuation.yield(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: ""))
                            }
                        case "content_block_delta":
                            let index = root["index"] as? Int ?? 0
                            if let delta = root["delta"] as? [String: Any] {
                                if (delta["type"] as? String) == "text_delta", let part = delta["text"] as? String {
                                    text += part; continuation.yield(.textDelta(part))
                                } else if (delta["type"] as? String) == "input_json_delta" {
                                    var tool = tools[index] ?? AnthropicToolAccumulator()
                                    let fragment = delta["partial_json"] as? String ?? ""
                                    tool.input += fragment
                                    tools[index] = tool
                                    continuation.yield(.toolCallDelta(index: index, id: tool.id, name: nil, argumentsDelta: fragment))
                                }
                            }
                        case "message_delta":
                            if let delta = root["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                                stop = reason == "tool_use" ? .toolUse : (reason == "max_tokens" ? .length : .stop)
                            }
                            if let raw = root["usage"] as? [String: Any] {
                                usage.outputTokens = raw["output_tokens"] as? Int ?? 0
                                continuation.yield(.usage(usage))
                            }
                        default: break
                        }
                    }
                    let decoder = JSONDecoder()
                    let calls = try tools.keys.sorted().compactMap { index -> ToolCall? in
                        guard let tool = tools[index], !tool.name.isEmpty else { return nil }
                        let raw = tool.input.trimmingCharacters(in: .whitespacesAndNewlines)
                        let args = raw.isEmpty ? JSONValue.object([:]) : try decoder.decode(JSONValue.self, from: Data(raw.utf8))
                        guard args.objectValue != nil else { throw ProviderFailure("invalid_tool_arguments", "Tool arguments for \(tool.name) must be a JSON object") }
                        return ToolCall(id: tool.id, name: tool.name, arguments: args)
                    }
                    if !calls.isEmpty { stop = .toolUse }
                    continuation.yield(.completed(AssistantTurn(text: text, toolCalls: calls, stopReason: stop, usage: usage)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderFailure("aborted", "Request cancelled"))
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeBody(_ request: ModelRequest) throws -> Data {
        var system: [String] = []
        var messages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system: system.append(message.text)
            case .user, .custom: messages.append(["role": "user", "content": message.text])
            case .assistant:
                var blocks: [[String: Any]] = []
                if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
                blocks += message.toolCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": foundationValue($0.arguments)] }
                messages.append(["role": "assistant", "content": blocks])
            case .toolResult:
                messages.append(["role": "user", "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": message.text, "is_error": message.isError ?? false]]])
            }
        }
        var body: [String: Any] = ["model": request.model.id, "messages": messages, "max_tokens": 8192, "stream": true]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { ["name": $0.name, "description": $0.description, "input_schema": foundationValue($0.inputSchema)] }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .object(let object): return object.mapValues(foundationValue)
        case .array(let array): return array.map(foundationValue)
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }
}

private struct AnthropicToolAccumulator {
    var id = ""
    var name = ""
    var input = ""
}
