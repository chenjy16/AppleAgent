import Foundation
import PiTypes
import PiProviders
import PiSession

public struct ToolContext: Sendable {
    public var workingDirectory: URL
    public var cancellation: CancellationToken
    public var sessionID: String
    public var processTimeout: TimeInterval
    public init(workingDirectory: URL, cancellation: CancellationToken, sessionID: String = "", processTimeout: TimeInterval = 120) {
        self.workingDirectory = workingDirectory; self.cancellation = cancellation
        self.sessionID = sessionID; self.processTimeout = processTimeout
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func throwIfCancelled() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
}

public enum ToolExecutionPolicy: Sendable { case parallelSafe, serialOnly }

/// Host-selected permission ceiling for tool execution.
public enum ToolPermissionPolicy: String, Sendable, Codable {
    case allowAll
    case readOnly
    case denyAll
    case ask
}

public enum ToolPermissionDecision: String, Sendable, Codable { case allowOnce, allowForSession, allowForProject, deny }

public struct AgentCommand: Sendable {
    public var name: String
    public var description: String
    public var sendsResultToAgent: Bool
    public var run: @Sendable ([String], Agent) async throws -> String
    public init(name: String, description: String,
                sendsResultToAgent: Bool = false,
                run: @escaping @Sendable ([String], Agent) async throws -> String) {
        self.name = name; self.description = description; self.sendsResultToAgent = sendsResultToAgent; self.run = run
    }
}

public protocol ToolPermissionGrantStore: Sendable {
    func containsSessionGrant(for request: ToolPermissionRequest) async throws -> Bool
    func saveSessionGrant(for request: ToolPermissionRequest) async throws
    func containsProjectGrant(for request: ToolPermissionRequest) async throws -> Bool
    func saveProjectGrant(for request: ToolPermissionRequest) async throws
    func revokeProjectGrants(for projectPath: String) async throws
}
public typealias ToolPermissionHandler = @Sendable (ToolPermissionRequest, CancellationToken) async -> ToolPermissionDecision

/// Native Swift extension point around tool execution. Hooks cannot override the host permission ceiling.
public protocol AgentMiddleware: Sendable {
    func beforeToolCall(_ call: ToolCall, tool: AgentTool, context: ToolContext) async throws
    func afterToolCall(_ call: ToolCall, result: ToolResult, context: ToolContext) async -> ToolResult
}

public extension AgentMiddleware {
    func beforeToolCall(_ call: ToolCall, tool: AgentTool, context: ToolContext) async throws {}
    func afterToolCall(_ call: ToolCall, result: ToolResult, context: ToolContext) async -> ToolResult { result }
}

public struct AgentTool: Sendable {
    public var declaration: ToolDeclaration
    public var executionPolicy: ToolExecutionPolicy
    public var permission: ToolPermission
    public var execute: @Sendable (String, JSONValue, ToolContext) async throws -> ToolResult
    public init(declaration: ToolDeclaration, executionPolicy: ToolExecutionPolicy = .parallelSafe,
                permission: ToolPermission = .external,
                execute: @escaping @Sendable (String, JSONValue, ToolContext) async throws -> ToolResult) {
        self.declaration = declaration; self.executionPolicy = executionPolicy
        self.permission = permission; self.execute = execute
    }
}

public actor Agent {
    private let provider: any ModelProvider
    private let store: any SessionStore
    private let options: RuntimeOptions
    private let permissionPolicy: ToolPermissionPolicy
    private let middleware: [any AgentMiddleware]
    private let permissionHandler: ToolPermissionHandler
    private let permissionGrantStore: (any ToolPermissionGrantStore)?
    private var sessionGrants: [ToolPermissionRequest] = []
    private var tools: [String: AgentTool]
    private let commands: [String: AgentCommand]
    private var session: SessionSnapshot
    private var activeCancellation: CancellationToken?
    private var activeTask: Task<Void, Never>?
    private var messages: [ConversationMessage]

    public init(provider: any ModelProvider, store: any SessionStore, session: SessionSnapshot,
                options: RuntimeOptions, tools: [AgentTool], permissionPolicy: ToolPermissionPolicy = .allowAll,
                middleware: [any AgentMiddleware] = [],
                permissionHandler: @escaping ToolPermissionHandler = { _, _ in .deny },
                permissionGrantStore: (any ToolPermissionGrantStore)? = nil,
                commands: [String: AgentCommand] = [:]) {
        self.provider = provider; self.store = store; self.session = session; self.options = options
        self.permissionPolicy = permissionPolicy
        self.middleware = middleware
        self.permissionHandler = permissionHandler
        self.permissionGrantStore = permissionGrantStore
        self.commands = commands
        self.tools = Dictionary(tools.map { ($0.declaration.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.messages = session.activeMessages
    }

    public func events(for prompt: String) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        if activeTask != nil {
            continuation.yield(.failed(code: "busy", message: "An agent run is already active"))
            continuation.yield(.agentEnd(messages: [], willRetry: false)); continuation.yield(.agentSettled(aborted: false)); continuation.finish()
            return stream
        }
        let token = CancellationToken()
        let task = Task { await self.run(prompt, token: token, continuation: continuation) }
        activeTask = task
        continuation.onTermination = { _ in token.cancel(); task.cancel() }
        return stream
    }

    public func abort() { activeCancellation?.cancel(); activeTask?.cancel() }
    public func currentMessages() -> [ConversationMessage] { messages }
    public func currentSessionID() -> String { session.id }
    public func currentSessionHeader() -> JSONValue { session.header }
    public func currentSessionFile() -> String? { session.fileURL?.path }
    public func commandNames() -> [String] { commands.keys.sorted() }
    public func commandSendsResultToAgent(_ name: String) -> Bool { commands[name]?.sendsResultToAgent ?? false }
    public func replaceTools(withPrefix prefix: String, using replacement: [AgentTool]) {
        var updated = tools.filter { !$0.key.hasPrefix(prefix) }
        for tool in replacement where tool.declaration.name.hasPrefix(prefix) {
            updated[tool.declaration.name] = tool
        }
        tools = updated
    }
    public func executeCommand(_ name: String, arguments: [String]) async throws -> String? {
        guard let command = commands[name] else { return nil }
        return try await command.run(arguments, self)
    }

    private func run(_ prompt: String, token: CancellationToken,
                     continuation: AsyncStream<AgentEvent>.Continuation) async {
        if activeCancellation != nil {
            continuation.yield(.failed(code: "busy", message: "An agent run is already active"))
            continuation.yield(.agentEnd(messages: [], willRetry: false)); continuation.yield(.agentSettled(aborted: false))
            continuation.finish(); return
        }
        activeCancellation = token
        let initialMessageCount = messages.count
        continuation.yield(.agentStart)
        do {
            let user = ConversationMessage(role: .user, text: prompt)
            try await append(user)
            continuation.yield(.messageStart(user)); continuation.yield(.messageEnd(user))
            var settledNormally = false
            for _ in 0..<max(1, options.maximumTurns) {
                try token.throwIfCancelled()
                try await compactContextIfNeeded(token: token)
                continuation.yield(.turnStart)
                var response: AssistantTurn?
                let streamingID = UUID().uuidString
                let streamingMessage = ConversationMessage(id: streamingID, role: .assistant)
                continuation.yield(.messageStart(streamingMessage))
                let request = ModelRequest(model: options.model,
                                           messages: [ConversationMessage(role: .system, text: options.systemPrompt)] + messages,
                                           tools: tools.values.map(\.declaration).sorted { $0.name < $1.name })
                if !tools.isEmpty && (options.model.supportsTools == false || provider.capabilities.toolCalls == false) {
                    throw AgentFailure.unsupportedToolCalls(options.model.id)
                }
                var retryCount = 0
                while true {
                    var emittedProviderEvent = false
                    do {
                        for try await event in provider.stream(request) {
                            try token.throwIfCancelled()
                            switch event {
                            case .textDelta(let delta):
                                emittedProviderEvent = true
                                continuation.yield(.textDelta(messageID: streamingID, delta: delta))
                            case .thinkingDelta(let delta):
                                emittedProviderEvent = true
                                continuation.yield(.thinkingDelta(messageID: streamingID, delta: delta))
                            case .toolCallDelta(let index, let id, let name, let argumentsDelta):
                                emittedProviderEvent = true
                                continuation.yield(.toolCallDelta(messageID: streamingID, index: index, id: id, name: name, argumentsDelta: argumentsDelta))
                            case .usage(let usage):
                                emittedProviderEvent = true
                                continuation.yield(.usage(usage))
                            case .completed(let turn):
                                emittedProviderEvent = true
                                response = turn
                            }
                        }
                        break
                    } catch {
                        guard !emittedProviderEvent,
                              retryCount < options.providerRetryPolicy.maximumRetries,
                              Self.isRetryableProviderError(error) else { throw error }
                        try token.throwIfCancelled()
                        let multiplier = 1 << min(retryCount, 20)
                        let upperBound = min(options.providerRetryPolicy.maximumDelayMilliseconds,
                                             options.providerRetryPolicy.baseDelayMilliseconds * multiplier)
                        let delay = upperBound > 0 ? Int.random(in: 0...upperBound) : 0
                        retryCount += 1
                        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    }
                }
                guard let turn = response else { throw AgentFailure.missingFinalResponse }
                let assistant = ConversationMessage(id: streamingID, role: .assistant, text: turn.text, toolCalls: turn.toolCalls)
                try await append(assistant)
                continuation.yield(.messageEnd(assistant))
                if turn.toolCalls.isEmpty {
                    continuation.yield(.turnEnd(message: assistant, toolResults: []))
                    settledNormally = true
                    break
                }
                let toolResults: [ToolResult]
                let preflightErrors = turn.toolCalls.map { call -> String? in
                    guard let tool = tools[call.name] else { return "Unknown tool: \(call.name)" }
                    return JSONSchemaValidator.validate(call.arguments, against: tool.declaration.inputSchema)
                }
                if preflightErrors.contains(where: { $0 != nil }) {
                    for call in turn.toolCalls { continuation.yield(.toolStart(call: call)) }
                    toolResults = zip(turn.toolCalls, preflightErrors).map { call, error in
                        ToolResult(text: error ?? "Tool call skipped because another call failed validation", isError: true)
                    }
                } else {
                    let requiresSequential = turn.toolCalls.contains { call in
                        tools[call.name]?.executionPolicy == .serialOnly
                    }
                    if options.toolExecution == .parallel && !requiresSequential && turn.toolCalls.count > 1 {
                    for call in turn.toolCalls { continuation.yield(.toolStart(call: call)) }
                    toolResults = await executeInParallel(turn.toolCalls, token: token, continuation: continuation)
                    try token.throwIfCancelled()
                } else {
                    var ordered: [ToolResult] = []
                    for call in turn.toolCalls {
                        try token.throwIfCancelled()
                        continuation.yield(.toolStart(call: call))
                        ordered.append(await executeTool(call, token: token, continuation: continuation))
                    }
                    toolResults = ordered
                    }
                }
                for (call, result) in zip(turn.toolCalls, toolResults) {
                    let toolMessage = ConversationMessage(role: .toolResult, text: result.text,
                                                          toolCallID: call.id, toolName: call.name, isError: result.isError)
                    try await append(toolMessage)
                    continuation.yield(.toolEnd(callID: call.id, result: result))
                    continuation.yield(.messageStart(toolMessage)); continuation.yield(.messageEnd(toolMessage))
                }
                continuation.yield(.turnEnd(message: assistant, toolResults: toolResults))
            }
            if !settledNormally { throw AgentFailure.turnLimitReached }
            continuation.yield(.agentEnd(messages: Array(messages.dropFirst(initialMessageCount)), willRetry: false))
            continuation.yield(.agentSettled(aborted: false))
        } catch is CancellationError {
            continuation.yield(.failed(code: "aborted", message: "Run cancelled"))
            continuation.yield(.agentEnd(messages: Array(messages.dropFirst(initialMessageCount)), willRetry: false))
            continuation.yield(.agentSettled(aborted: true))
        } catch {
            continuation.yield(.failed(code: "agent_error", message: error.localizedDescription))
            continuation.yield(.agentEnd(messages: Array(messages.dropFirst(initialMessageCount)), willRetry: false))
            continuation.yield(.agentSettled(aborted: false))
        }
        activeCancellation = nil
        activeTask = nil
        continuation.finish()
    }


    private func executeTool(_ call: ToolCall, token: CancellationToken,
                             continuation: AsyncStream<AgentEvent>.Continuation) async -> ToolResult {
        guard let tool = tools[call.name] else { return ToolResult(text: "Unknown tool: \(call.name)", isError: true) }
        do {
            try token.throwIfCancelled()
            if let validationError = JSONSchemaValidator.validate(call.arguments, against: tool.declaration.inputSchema) {
                throw ToolArgumentFailure(validationError)
            }
            let context = ToolContext(workingDirectory: options.workingDirectory, cancellation: token,
                                      sessionID: session.id)
            let allowed: Bool
            switch permissionPolicy {
            case .allowAll: allowed = true
            case .readOnly: allowed = tool.permission == .readOnly
            case .denyAll: allowed = false
            case .ask:
                let request = ToolPermissionRequest(toolName: call.name, permission: tool.permission,
                                                    arguments: call.arguments, sessionID: session.id,
                                                    projectPath: options.workingDirectory.standardizedFileURL.path)
                let localSessionGrant = sessionGrants.contains(where: { Self.sameGrant($0, request) })
                let sharedSessionGrant: Bool
                if let permissionGrantStore {
                    sharedSessionGrant = try await permissionGrantStore.containsSessionGrant(for: request)
                } else {
                    sharedSessionGrant = false
                }
                if localSessionGrant || sharedSessionGrant {
                    allowed = true
                    break
                }
                if let permissionGrantStore, try await permissionGrantStore.containsProjectGrant(for: request) {
                    allowed = true
                    break
                }
                continuation.yield(.permissionRequest(request))
                switch await permissionHandler(request, token) {
                case .allowOnce: allowed = true
                case .allowForSession:
                    sessionGrants.append(request)
                    try await permissionGrantStore?.saveSessionGrant(for: request)
                    allowed = true
                case .allowForProject:
                    guard let permissionGrantStore else {
                        throw ToolPermissionFailure(tool: call.name, permission: tool.permission, policy: permissionPolicy)
                    }
                    try await permissionGrantStore.saveProjectGrant(for: request)
                    allowed = true
                case .deny: allowed = false
                }
            }
            guard allowed else { throw ToolPermissionFailure(tool: call.name, permission: tool.permission, policy: permissionPolicy) }
            for hook in middleware { try await hook.beforeToolCall(call, tool: tool, context: context) }
            var result = try await tool.execute(call.id, call.arguments, context)
            for hook in middleware { result = await hook.afterToolCall(call, result: result, context: context) }
            return result
        } catch { return ToolResult(text: error.localizedDescription, isError: true) }
    }

    private func executeInParallel(_ calls: [ToolCall], token: CancellationToken,
                                   continuation: AsyncStream<AgentEvent>.Continuation) async -> [ToolResult] {
        await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { (index, await self.executeTool(call, token: token, continuation: continuation)) }
            }
            var results = Array<ToolResult?>(repeating: nil, count: calls.count)
            for await (index, result) in group { results[index] = result }
            return results.map { $0 ?? ToolResult(text: "Tool execution did not return a result", isError: true) }
        }
    }

    private static func isRetryableProviderError(_ error: Error) -> Bool {
        if let failure = error as? ProviderFailure {
            guard let status = failure.statusCode else { return false }
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if let urlError = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable].contains(urlError.code)
        }
        return false
    }

    private static func sameGrant(_ lhs: ToolPermissionRequest, _ rhs: ToolPermissionRequest) -> Bool {
        lhs.toolName == rhs.toolName && lhs.permission == rhs.permission && lhs.arguments == rhs.arguments
    }

    private func append(_ message: ConversationMessage) async throws {
        session = try await store.append(message, to: session)
        messages = session.activeMessages
    }

    private func compactContextIfNeeded(token: CancellationToken) async throws {
        let policy = options.contextCompactionPolicy
        guard policy.enabled,
              let contextWindow = options.model.contextWindow ?? provider.capabilities.contextWindow,
              contextWindow > 0 else { return }
        let currentTokens = Self.estimatedTokens(messages: messages, systemPrompt: options.systemPrompt,
                                                 tools: tools.values.map(\.declaration))
        guard Double(currentTokens) > Double(contextWindow) * policy.triggerRatio else { return }

        var firstKeptIndex = max(0, messages.count - policy.recentMessagesToKeep)
        guard firstKeptIndex > 0 else { return }
        let targetTokens = Int(Double(contextWindow) * policy.targetRatio)
        // Never split an assistant tool call from its corresponding tool result.
        if firstKeptIndex < messages.count, messages[firstKeptIndex].role == .toolResult,
           let callID = messages[firstKeptIndex].toolCallID,
           let assistantIndex = messages[..<firstKeptIndex].lastIndex(where: { message in
               message.role == .assistant && message.toolCalls.contains(where: { $0.id == callID })
           }) {
            firstKeptIndex = assistantIndex
        }
        let entryIDs = Set(session.entries.map(\.id))
        while firstKeptIndex < messages.count && !entryIDs.contains(messages[firstKeptIndex].id) {
            firstKeptIndex += 1
        }
        guard firstKeptIndex > 0, firstKeptIndex < messages.count,
              let firstKeptEntryID = messages[firstKeptIndex...].first(where: { entryIDs.contains($0.id) })?.id else { return }
        let oldMessages = Array(messages[..<firstKeptIndex])
        let request = ModelRequest(model: options.model, messages: [
            ConversationMessage(role: .system, text: "Summarize the earlier conversation for future turns in at most about \(targetTokens) tokens. Preserve user goals, decisions, constraints, important facts, file paths, and unresolved tasks. Do not answer the original request; return only a concise factual summary.")
        ] + oldMessages, tools: [])
        var summary = ""
        for try await event in provider.stream(request) {
            try token.throwIfCancelled()
            if case .completed(let turn) = event { summary = turn.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !summary.isEmpty else { throw AgentFailure.contextCompactionFailed }
        session = try await store.appendCompaction(summary: summary, firstKeptEntryID: firstKeptEntryID, to: session)
        messages = session.activeMessages
    }

    private static func estimatedTokens(messages: [ConversationMessage], systemPrompt: String,
                                        tools: [ToolDeclaration]) -> Int {
        let messageBytes = messages.reduce(systemPrompt.utf8.count) { total, message in
            total + message.text.utf8.count + message.toolCalls.reduce(0) { $0 + $1.arguments.encodedData.count + $1.name.utf8.count }
        }
        let toolBytes = tools.reduce(0) { $0 + $1.name.utf8.count + $1.description.utf8.count + $1.inputSchema.encodedData.count }
        return (messageBytes + toolBytes) / 4 + messages.count * 4 + tools.count * 8
    }
}

private struct ToolPermissionFailure: Error, LocalizedError {
    let tool: String
    let permission: ToolPermission
    let policy: ToolPermissionPolicy
    var errorDescription: String? {
        "Tool '\(tool)' requires \(permission.rawValue) permission; current policy is \(policy.rawValue)"
    }
}

public enum AgentFailure: Error, LocalizedError {
    case missingFinalResponse
    case turnLimitReached
    case unsupportedToolCalls(String)
    case contextCompactionFailed
    public var errorDescription: String? {
        switch self {
        case .missingFinalResponse: return "Provider stream ended without a final response"
        case .turnLimitReached: return "Maximum agent turn count reached"
        case .unsupportedToolCalls(let model): return "Model '\(model)' does not support tool calls"
        case .contextCompactionFailed: return "The provider returned an empty context summary; the session was not compacted"
        }
    }
}


private struct ToolArgumentFailure: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

public enum JSONSchemaValidator {
    public static func validate(_ value: JSONValue, against schema: JSONValue) -> String? {
        guard let object = schema.objectValue else { return nil }
        let type = object["type"]?.stringValue
        switch type {
        case "object":
            guard let valueObject = value.objectValue else { return "Tool arguments must be an object" }
            let required = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for key in required where valueObject[key] == nil { return "Missing required argument: \(key)" }
            let properties = object["properties"]?.objectValue ?? [:]
            if object["additionalProperties"]?.boolValue == false,
               let unknown = valueObject.keys.first(where: { properties[$0] == nil }) {
                return "Unknown argument: \(unknown)"
            }
            for (key, child) in valueObject {
                if let childSchema = properties[key], let error = validate(child, against: childSchema) {
                    return "\(key): \(error)"
                }
            }
        case "string": if case .string = value { return nil }; return "Expected a string"
        case "number": if case .number = value { return nil }; return "Expected a number"
        case "integer":
            if case .number(let number) = value, number.rounded() == number { return nil }
            return "Expected an integer"
        case "boolean": if case .bool = value { return nil }; return "Expected a boolean"
        case "array": if case .array = value { return nil }; return "Expected an array"
        case "null": if case .null = value { return nil }; return "Expected null"
        default: break
        }
        if let values = object["enum"]?.arrayValue, !values.contains(value) { return "Value is not in the allowed set" }
        return nil
    }
}
