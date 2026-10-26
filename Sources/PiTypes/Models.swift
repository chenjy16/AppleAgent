import Foundation

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var encodedData: Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }
}

public enum MessageRole: String, Codable, Sendable { case system, user, assistant, toolResult, custom }

public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: MessageRole
    public var timestamp: Date
    public var text: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var isError: Bool?

    public init(id: String = UUID().uuidString, role: MessageRole, timestamp: Date = .now,
                text: String = "", toolCalls: [ToolCall] = [], toolCallID: String? = nil,
                toolName: String? = nil, isError: Bool? = nil) {
        self.id = id; self.role = role; self.timestamp = timestamp; self.text = text
        self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.toolName = toolName; self.isError = isError
    }
}

public struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var providerID: String
    public var contextWindow: Int?
    /// `nil` means the catalog did not provide a reliable capability value.
    public var supportsTools: Bool?
    public var imageInput: Bool?
    public var reasoning: Bool?
    public var streaming: Bool?
    public init(id: String, providerID: String, contextWindow: Int? = nil, supportsTools: Bool? = nil,
                imageInput: Bool? = nil, reasoning: Bool? = nil, streaming: Bool? = nil) {
        self.id = id; self.providerID = providerID; self.contextWindow = contextWindow
        self.supportsTools = supportsTools; self.imageInput = imageInput
        self.reasoning = reasoning; self.streaming = streaming
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public enum StopReason: String, Codable, Sendable { case stop, toolUse, length, error, aborted, unknown }

public struct AssistantTurn: Codable, Sendable, Equatable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var stopReason: StopReason
    public var usage: TokenUsage?
    public init(text: String = "", toolCalls: [ToolCall] = [], stopReason: StopReason = .stop, usage: TokenUsage? = nil) {
        self.text = text; self.toolCalls = toolCalls; self.stopReason = stopReason; self.usage = usage
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public var text: String
    public var details: JSONValue?
    public var isError: Bool
    public init(text: String, details: JSONValue? = nil, isError: Bool = false) {
        self.text = text; self.details = details; self.isError = isError
    }
}

public enum ToolPermission: String, Sendable, Codable { case readOnly, workspaceWrite, shell, external }

public struct ToolPermissionRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var toolName: String
    public var permission: ToolPermission
    public var arguments: JSONValue
    public var sessionID: String?
    public var projectPath: String?
    public init(id: String = UUID().uuidString, toolName: String, permission: ToolPermission,
                arguments: JSONValue, sessionID: String? = nil, projectPath: String? = nil) {
        self.id = id; self.toolName = toolName; self.permission = permission; self.arguments = arguments
        self.sessionID = sessionID; self.projectPath = projectPath
    }
}

public enum AgentEvent: Codable, Sendable, Equatable {
    case agentStart
    case turnStart
    case messageStart(ConversationMessage)
    case textDelta(messageID: String, delta: String)
    case thinkingDelta(messageID: String, delta: String)
    case toolCallDelta(messageID: String, index: Int, id: String?, name: String?, argumentsDelta: String)
    case usage(TokenUsage)
    case messageEnd(ConversationMessage)
    case toolStart(call: ToolCall)
    case toolEnd(callID: String, result: ToolResult)
    case permissionRequest(ToolPermissionRequest)
    case turnEnd(message: ConversationMessage, toolResults: [ToolResult])
    case agentEnd(messages: [ConversationMessage], willRetry: Bool)
    case agentSettled(aborted: Bool)
    case failed(code: String, message: String)
}

public struct ProviderRetryPolicy: Sendable, Equatable {
    public var maximumRetries: Int
    public var baseDelayMilliseconds: Int
    public var maximumDelayMilliseconds: Int
    public init(maximumRetries: Int = 2, baseDelayMilliseconds: Int = 250,
                maximumDelayMilliseconds: Int = 2_000) {
        self.maximumRetries = min(5, max(0, maximumRetries))
        self.baseDelayMilliseconds = min(60_000, max(0, baseDelayMilliseconds))
        self.maximumDelayMilliseconds = min(60_000, max(0, maximumDelayMilliseconds))
    }
}

public struct ContextCompactionPolicy: Sendable, Equatable {
    public var enabled: Bool
    public var triggerRatio: Double
    public var targetRatio: Double
    public var recentMessagesToKeep: Int

    public init(enabled: Bool = true, triggerRatio: Double = 0.80,
                targetRatio: Double = 0.55, recentMessagesToKeep: Int = 8) {
        self.enabled = enabled
        self.triggerRatio = min(0.95, max(0.20, triggerRatio))
        self.targetRatio = min(self.triggerRatio - 0.05, max(0.05, targetRatio))
        self.recentMessagesToKeep = min(100, max(2, recentMessagesToKeep))
    }
}

public struct RuntimeOptions: Sendable {
    public var model: ModelDescriptor
    public var providerRetryPolicy: ProviderRetryPolicy
    public var contextCompactionPolicy: ContextCompactionPolicy
    public var workingDirectory: URL
    public var systemPrompt: String
    public var maximumTurns: Int
    public var toolExecution: ToolExecutionMode
    public init(model: ModelDescriptor, workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                systemPrompt: String = "You are a helpful coding assistant.", maximumTurns: Int = 12,
                toolExecution: ToolExecutionMode = .sequential,
                providerRetryPolicy: ProviderRetryPolicy = .init(),
                contextCompactionPolicy: ContextCompactionPolicy = .init()) {
        self.model = model; self.workingDirectory = workingDirectory; self.systemPrompt = systemPrompt
        self.maximumTurns = maximumTurns; self.toolExecution = toolExecution
        self.providerRetryPolicy = providerRetryPolicy
        self.contextCompactionPolicy = contextCompactionPolicy
    }
}

public enum ToolExecutionMode: String, Codable, Sendable { case sequential, parallel }
