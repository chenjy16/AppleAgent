import Foundation
import PiTypes

public struct ToolDeclaration: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

public struct ModelRequest: Sendable {
    public var model: ModelDescriptor
    public var messages: [ConversationMessage]
    public var tools: [ToolDeclaration]
    public var temperature: Double?
    public init(model: ModelDescriptor, messages: [ConversationMessage], tools: [ToolDeclaration], temperature: Double? = nil) {
        self.model = model; self.messages = messages; self.tools = tools; self.temperature = temperature
    }
}

public struct ProviderCapabilities: Codable, Sendable, Equatable {
    public var streaming: Bool
    public var toolCalls: Bool
    public var imageInput: Bool
    public var reasoning: Bool
    public var contextWindow: Int?
    public init(streaming: Bool = true, toolCalls: Bool = true, imageInput: Bool = false,
                reasoning: Bool = false, contextWindow: Int? = nil) {
        self.streaming = streaming; self.toolCalls = toolCalls; self.imageInput = imageInput
        self.reasoning = reasoning; self.contextWindow = contextWindow
    }
}

public enum ModelStreamEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String)
    case usage(TokenUsage)
    case completed(AssistantTurn)
}

public protocol ModelProvider: Sendable {
    var id: String { get }
    var capabilities: ProviderCapabilities { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

public extension ModelProvider {
    var capabilities: ProviderCapabilities { ProviderCapabilities() }
}

public struct ProviderFailure: Error, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var statusCode: Int?
    public var requestID: String?
    public init(_ code: String, _ message: String, statusCode: Int? = nil, requestID: String? = nil) {
        self.code = code; self.message = message; self.statusCode = statusCode; self.requestID = requestID
    }
    public var errorDescription: String? {
        let request = requestID.map { " [request \($0)]" } ?? ""
        return "\(code): \(message)\(request)"
    }
}
