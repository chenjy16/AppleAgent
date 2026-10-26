import Foundation
import PiTypes
import PiRuntime
import PiAgentCore

private actor RPCOutput {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }
}

private actor RPCPermissionBroker {
    private var pending: [String: CheckedContinuation<ToolPermissionDecision, Never>] = [:]

    func request(_ request: ToolPermissionRequest, cancellation: CancellationToken) async -> ToolPermissionDecision {
        guard !cancellation.isCancelled else { return .deny }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[request.id] = continuation
                Task {
                    try? await Task.sleep(for: .seconds(60))
                    self.resolve(requestID: request.id, decision: .deny)
                }
            }
        } onCancel: {
            Task { await self.resolve(requestID: request.id, decision: .deny) }
        }
    }

    @discardableResult
    func resolve(requestID: String, decision: ToolPermissionDecision) -> Bool {
        guard let continuation = pending.removeValue(forKey: requestID) else { return false }
        continuation.resume(returning: decision)
        return true
    }
}

public actor RPCHost {
    public typealias AgentFactory = @Sendable (_ sessionID: String?, _ providerID: String?, _ modelID: String?, _ parentSession: String?, _ permissionHandler: @escaping ToolPermissionHandler) async throws -> Agent
    private let makeAgent: AgentFactory
    private let output: RPCOutput
    private let permissionBroker = RPCPermissionBroker()
    private var agent: Agent?
    private var sessionID: String?
    private var providerID: String?
    private var modelID: String?
    private var runTask: Task<Void, Never>?
    private struct QueuedPrompt: Sendable {
        var message: String
    }
    private var queuedPrompts: [QueuedPrompt] = []
    private let maximumQueuedPrompts = 64
    private var isShutdown = false

    public init(output: FileHandle = .standardOutput, sessionID: String? = nil,
                providerID: String? = nil, modelID: String? = nil,
                makeAgent: @escaping AgentFactory) {
        self.sessionID = sessionID; self.providerID = providerID; self.modelID = modelID
        self.makeAgent = makeAgent; self.output = RPCOutput(output)
    }

    /// Reads records by LF bytes only. Unicode line separators inside JSON strings remain ordinary content.
    public func run(input: FileHandle = .standardInput) async {
        var record = Data()
        do {
            for try await byte in input.bytes {
                if byte == 0x0A {
                    if record.last == 0x0D { record.removeLast() }
                    try await handleLine(record)
                    record.removeAll(keepingCapacity: true)
                } else {
                    record.append(byte)
                }
                if isShutdown { break }
            }
            if !record.isEmpty && !isShutdown { try await handleLine(record) }
        } catch {
            FileHandle.standardError.write(Data("RPC input error: \(error.localizedDescription)\n".utf8))
        }
        await agent?.abort()
        await runTask?.value
    }

    private func handleLine(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RPCFailure("Command must be a JSON object")
            }
            try await handle(request)
        } catch {
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            try await response(request?["id"] as? String, request?["type"] as? String ?? "parse", false,
                               error.localizedDescription)
        }
    }

    private func handle(_ request: [String: Any]) async throws {
        let type = request["type"] as? String ?? ""
        let id = request["id"] as? String
        switch type {
        case "prompt":
            guard let prompt = request["message"] as? String, !prompt.isEmpty else {
                try await response(id, type, false, "message is required"); return
            }
            let behavior = request["streamingBehavior"] as? String
            if runTask != nil {
                switch behavior {
                case "steer":
                    guard queuedPrompts.count < maximumQueuedPrompts else {
                        try await response(id, type, false, "Prompt queue is full (limit: \(maximumQueuedPrompts))"); return
                    }
                    queuedPrompts.insert(QueuedPrompt(message: prompt), at: 0)
                    await agent?.abort()
                    try await response(id, type, true, nil, data: ["disposition": "steering"])
                case "followUp", "follow_up":
                    guard queuedPrompts.count < maximumQueuedPrompts else {
                        try await response(id, type, false, "Prompt queue is full (limit: \(maximumQueuedPrompts))"); return
                    }
                    queuedPrompts.append(QueuedPrompt(message: prompt))
                    try await response(id, type, true, nil, data: ["disposition": "queued"])
                default:
                    try await response(id, type, false, "Agent is busy; use streamingBehavior 'steer' or 'followUp'")
                }
                return
            }
            try await startPrompt(prompt, responseID: id, responseType: type)
        case "steer", "follow_up":
            guard let prompt = request["message"] as? String, !prompt.isEmpty else {
                try await response(id, type, false, "message is required"); return
            }
            guard runTask != nil else {
                try await startPrompt(prompt, responseID: id, responseType: type); return
            }
            if type == "steer" {
                guard queuedPrompts.count < maximumQueuedPrompts else {
                    try await response(id, type, false, "Prompt queue is full (limit: \(maximumQueuedPrompts))"); return
                }
                queuedPrompts.insert(QueuedPrompt(message: prompt), at: 0)
                await agent?.abort()
                try await response(id, type, true, nil, data: ["disposition": "steering"])
            } else {
                guard queuedPrompts.count < maximumQueuedPrompts else {
                    try await response(id, type, false, "Prompt queue is full (limit: \(maximumQueuedPrompts))"); return
                }
                queuedPrompts.append(QueuedPrompt(message: prompt))
                try await response(id, type, true, nil, data: ["disposition": "queued"])
            }
        case "execute_command":
            guard runTask == nil else { try await response(id, type, false, "Cannot run a plugin command while the Agent is active"); return }
            guard let command = request["command"] as? String, !command.isEmpty else {
                try await response(id, type, false, "command is required"); return
            }
            let arguments = request["args"] as? [String] ?? []
            let current = try await getAgent()
            guard let output = try await current.executeCommand(command, arguments: arguments) else {
                try await response(id, type, false, "Unknown command: \(command)"); return
            }
            try await response(id, type, true, nil, data: ["output": output])
        case "abort":
            await agent?.abort()
            await runTask?.value
            try await response(id, type, true, nil)
        case "get_state":
            let current = try await getAgent()
            let messages = await current.currentMessages()
            try await response(id, type, true, nil, data: [
                "sessionId": await current.currentSessionID(), "sessionFile": await current.currentSessionFile() ?? "",
                "model": modelID ?? "", "provider": providerID ?? "", "isStreaming": runTask != nil,
                "messageCount": messages.count, "queuedPromptCount": queuedPrompts.count
            ])
        case "get_messages":
            let current = try await getAgent()
            try await response(id, type, true, nil, data: ["messages": await current.currentMessages().map(Self.messageObject)])
        case "new_session":
            guard runTask == nil else { try await response(id, type, false, "Cannot change sessions while an agent run is active"); return }
            agent = try await createAgent(nil, providerID, modelID, request["parentSession"] as? String)
            sessionID = await agent?.currentSessionID()
            let current = try await getAgent()
            try await response(id, type, true, nil, data: ["cancelled": false, "sessionId": sessionID ?? "", "sessionFile": await current.currentSessionFile() ?? ""])
        case "switch_session":
            guard runTask == nil else { try await response(id, type, false, "Cannot change sessions while an agent run is active"); return }
            guard let requested = (request["sessionPath"] as? String) ?? (request["sessionId"] as? String), !requested.isEmpty else {
                try await response(id, type, false, "sessionPath or sessionId is required"); return
            }
            let switched = try await createAgent(requested, providerID, modelID, nil)
            agent = switched; sessionID = await switched.currentSessionID()
            try await response(id, type, true, nil, data: ["cancelled": false, "sessionId": sessionID ?? "", "sessionFile": await switched.currentSessionFile() ?? ""])
        case "set_model":
            guard runTask == nil else { try await response(id, type, false, "Cannot change models while an agent run is active"); return }
            guard let provider = request["provider"] as? String, let model = request["modelId"] as? String else {
                try await response(id, type, false, "provider and modelId are required"); return
            }
            let updated = try await createAgent(sessionID, provider, model, nil)
            agent = updated; sessionID = await updated.currentSessionID(); providerID = provider; modelID = model
            try await response(id, type, true, nil, data: ["provider": provider, "id": model])
        case "shutdown":
            isShutdown = true; await agent?.abort(); await runTask?.value
            try await response(id, type, true, nil)
        case "permission_response":
            guard let requestID = request["requestId"] as? String else {
                try await response(id, type, false, "requestId is required"); return
            }
            let decision: ToolPermissionDecision
            if let raw = request["decision"] as? String, let parsed = ToolPermissionDecision(rawValue: raw) {
                decision = parsed
            } else if let approved = request["approved"] as? Bool {
                decision = approved ? .allowOnce : .deny
            } else {
                try await response(id, type, false, "decision or approved is required"); return
            }
            let resolved = await permissionBroker.resolve(requestID: requestID, decision: decision)
            try await response(id, type, resolved, resolved ? nil : "Permission request is unknown, expired, or already resolved")
        default:
            try await response(id, type, false, "Unsupported command: \(type)")
        }
    }

    private func getAgent() async throws -> Agent {
        if let agent { return agent }
        let created = try await createAgent(sessionID, providerID, modelID, nil)
        agent = created; sessionID = await created.currentSessionID()
        return created
    }

    private func createAgent(_ session: String?, _ provider: String?, _ model: String?, _ parent: String?) async throws -> Agent {
        let broker = permissionBroker
        let handler: ToolPermissionHandler = { request, cancellation in
            await broker.request(request, cancellation: cancellation)
        }
        return try await makeAgent(session, provider, model, parent, handler)
    }

    private func startPrompt(_ prompt: String, responseID: String?, responseType: String) async throws {
        let current = try await getAgent()
        let stream = await current.events(for: prompt)
        try await response(responseID, responseType, true, nil, data: ["disposition": "started"])
        launch(stream)
    }

    private func launch(_ stream: AsyncStream<AgentEvent>) {
        runTask = Task { [weak self, output] in
            for await event in stream {
                do { try await output.write(Self.encode(Self.eventObject(event))) }
                catch { FileHandle.standardError.write(Data("RPC output error: \(error.localizedDescription)\n".utf8)); break }
            }
            await self?.runDidFinish()
        }
    }

    private func runDidFinish() {
        runTask = nil
        guard !isShutdown, !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        Task { await self.startQueuedPrompt(next.message) }
    }

    private func startQueuedPrompt(_ prompt: String) async {
        guard !isShutdown, runTask == nil else {
            if !isShutdown { queuedPrompts.insert(QueuedPrompt(message: prompt), at: 0) }
            return
        }
        do {
            let current = try await getAgent()
            let stream = await current.events(for: prompt)
            launch(stream)
        } catch {
            do { try await output.write(Self.encode(["type": "error", "code": "queued_prompt_failed", "message": error.localizedDescription])) }
            catch { FileHandle.standardError.write(Data("RPC output error: \(error.localizedDescription)\n".utf8)) }
        }
    }

    private func response(_ id: String?, _ command: String, _ success: Bool, _ error: String?,
                          data: [String: Any]? = nil) async throws {
        var value: [String: Any] = ["type": "response", "command": command, "success": success]
        if let id { value["id"] = id }
        if let error { value["error"] = error }
        if let data { value["data"] = data }
        try await output.write(Self.encode(value))
    }

    private static func encode(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
    }

    private static func eventObject(_ event: AgentEvent) -> [String: Any] {
        switch event {
        case .agentStart: return ["type": "agent_start"]
        case .turnStart: return ["type": "turn_start"]
        case .messageStart(let message): return ["type": "message_start", "message": messageObject(message)]
        case .textDelta(let messageID, let delta): return ["type": "message_update", "messageId": messageID, "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": delta]]
        case .thinkingDelta(let messageID, let delta): return ["type": "message_update", "messageId": messageID, "assistantMessageEvent": ["type": "thinking_delta", "contentIndex": 0, "delta": delta]]
        case .toolCallDelta(let messageID, let index, let id, let name, let argumentsDelta):
            var partial: [String: Any] = ["argumentsDelta": argumentsDelta]
            if let id { partial["id"] = id }; if let name { partial["name"] = name }
            return ["type": "message_update", "messageId": messageID,
                    "assistantMessageEvent": ["type": "tool_call_delta", "contentIndex": index, "delta": partial]]
        case .usage(let usage): return ["type": "message_update", "usage": ["input": usage.inputTokens, "output": usage.outputTokens]]
        case .messageEnd(let message): return ["type": "message_end", "message": messageObject(message)]
        case .toolStart(let call): return ["type": "tool_execution_start", "toolCallId": call.id, "toolName": call.name, "args": jsonObject(call.arguments)]
        case .toolEnd(let id, let result): return ["type": "tool_execution_end", "toolCallId": id, "result": ["content": [["type": "text", "text": result.text]], "isError": result.isError]]
        case .permissionRequest(let request):
            var value: [String: Any] = ["id": request.id, "toolName": request.toolName,
                                        "permission": request.permission.rawValue, "arguments": jsonObject(request.arguments)]
            if let sessionID = request.sessionID { value["sessionId"] = sessionID }
            if let projectPath = request.projectPath { value["projectPath"] = projectPath }
            return ["type": "permission_request", "request": value]
        case .turnEnd(let message, let results):
            let toolResults = zip(message.toolCalls, results).map { call, result in
                ["toolCallId": call.id, "toolName": call.name,
                 "content": [["type": "text", "text": result.text]], "isError": result.isError] as [String: Any]
            }
            return ["type": "turn_end", "message": messageObject(message), "toolResults": toolResults]
        case .agentEnd(let messages, let willRetry):
            return ["type": "agent_end", "messages": messages.map(messageObject), "willRetry": willRetry]
        case .agentSettled(let aborted): return ["type": "agent_settled", "aborted": aborted]
        case .failed(let code, let message): return ["type": "error", "code": code, "message": message]
        }
    }

    private static func messageObject(_ message: ConversationMessage) -> [String: Any] {
        let blocks: [[String: Any]] = (message.text.isEmpty ? [] : [["type": "text", "text": message.text]]) + message.toolCalls.map {
            ["type": "toolCall", "id": $0.id, "name": $0.name, "arguments": jsonObject($0.arguments)]
        }
        let content: Any = message.role == .assistant ? blocks : (message.role == .toolResult ? [["type": "text", "text": message.text]] : message.text)
        var object: [String: Any] = ["role": message.role.rawValue, "content": content,
                                     "timestamp": Int(message.timestamp.timeIntervalSince1970 * 1000)]
        if let toolCallID = message.toolCallID { object["toolCallId"] = toolCallID }
        if let toolName = message.toolName { object["toolName"] = toolName }
        if let isError = message.isError { object["isError"] = isError }
        return object
    }

    private static func jsonObject(_ value: JSONValue) -> Any {
        switch value {
        case .object(let value): return value.mapValues(jsonObject)
        case .array(let value): return value.map(jsonObject)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

private struct RPCFailure: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
