import Foundation
import PiTypes
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAICompatibleProvider: ModelProvider, ModelCatalogSource {
    public let id: String
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(id: String = "openai", baseURL: URL = URL(string: "https://api.openai.com/v1")!,
                apiKey: String, session: URLSession = .shared) {
        self.id = id; self.baseURL = baseURL; self.apiKey = apiKey; self.session = session
    }

    public var catalogProviderID: String { id }

    public func fetchModels() async throws -> [ModelDescriptor] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure("invalid_response", "Expected HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderFailure("http_\(http.statusCode)", String(decoding: data.prefix(8_000), as: UTF8.self),
                                  statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-request-id"))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw ProviderFailure("invalid_response", "Model catalog response has no data array")
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ModelDescriptor(id: id, providerID: self.id)
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try Self.makeBody(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw ProviderFailure("invalid_response", "Expected HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n"; if body.count > 8_000 { break } }
                        throw ProviderFailure("http_\(http.statusCode)", body.trimmingCharacters(in: .whitespacesAndNewlines),
                                              statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-request-id"))
                    }
                    var text = ""
                    var calls: [Int: CallAccumulator] = [:]
                    var usage: TokenUsage?
                    var finish: StopReason = .unknown
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let rawUsage = root["usage"] as? [String: Any] {
                            usage = TokenUsage(inputTokens: rawUsage["prompt_tokens"] as? Int ?? 0,
                                               outputTokens: rawUsage["completion_tokens"] as? Int ?? 0)
                            if let usage { continuation.yield(.usage(usage)) }
                        }
                        guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                        if let reason = choice["finish_reason"] as? String {
                            finish = reason == "tool_calls" ? .toolUse : (reason == "length" ? .length : .stop)
                        }
                        guard let delta = choice["delta"] as? [String: Any] else { continue }
                        if let part = delta["content"] as? String, !part.isEmpty {
                            text += part
                            continuation.yield(.textDelta(part))
                        }
                        if let fragments = delta["tool_calls"] as? [[String: Any]] {
                            for fragment in fragments {
                                let index = fragment["index"] as? Int ?? 0
                                var call = calls[index] ?? CallAccumulator()
                                if let id = fragment["id"] as? String { call.id += id }
                                var nameDelta: String?
                                var argumentsDelta = ""
                                if let function = fragment["function"] as? [String: Any] {
                                    nameDelta = function["name"] as? String
                                    let rawName = nameDelta ?? ""
                                    call.name += rawName
                                    argumentsDelta = function["arguments"] as? String ?? ""
                                    call.arguments += argumentsDelta
                                }
                                calls[index] = call
                                continuation.yield(.toolCallDelta(index: index, id: fragment["id"] as? String,
                                                                  name: nameDelta, argumentsDelta: argumentsDelta))
                            }
                        }
                    }
                    let decoder = JSONDecoder()
                    let toolCalls = calls.keys.sorted().compactMap { index -> ToolCall? in
                        guard let call = calls[index], !call.name.isEmpty else { return nil }
                        let data = Data(call.arguments.utf8)
                        let arguments = (try? decoder.decode(JSONValue.self, from: data)) ?? .object([:])
                        return ToolCall(id: call.id.isEmpty ? UUID().uuidString : call.id, name: call.name, arguments: arguments)
                    }
                    if !toolCalls.isEmpty { finish = .toolUse }
                    continuation.yield(.completed(AssistantTurn(text: text, toolCalls: toolCalls, stopReason: finish, usage: usage)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderFailure("aborted", "Request cancelled"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeBody(_ request: ModelRequest) throws -> Data {
        var messages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system, .user, .custom:
                messages.append(["role": message.role == .system ? "system" : "user", "content": message.text])
            case .assistant:
                var item: [String: Any] = ["role": "assistant", "content": message.text.isEmpty ? NSNull() : message.text]
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": String(data: call.arguments.encodedData, encoding: .utf8) ?? "{}"]] as [String: Any]
                    }
                }
                messages.append(item)
            case .toolResult:
                messages.append(["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text])
            }
        }
        var body: [String: Any] = ["model": request.model.id, "messages": messages, "stream": true,
                                   "stream_options": ["include_usage": true]]
        if let temperature = request.temperature { body["temperature"] = temperature }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": Self.foundationValue(tool.inputSchema)]] as [String: Any]
            }
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

private struct CallAccumulator {
    var id = ""
    var name = ""
    var arguments = ""
}
