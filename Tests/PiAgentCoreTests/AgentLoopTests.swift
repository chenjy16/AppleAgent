import Foundation
import XCTest
import PiTypes
import PiProviders
import PiSession
import PiAgentCore

private actor PermissionTestCounter {
    private var approvals = 0
    private var executions = 0
    func recordApproval() { approvals += 1 }
    func recordExecution() { executions += 1 }
    func values() -> (Int, Int) { (approvals, executions) }
}


private final class RetryScriptProvider: ModelProvider, @unchecked Sendable {
    let id = "retry-fixture"
    let capabilities: ProviderCapabilities
    private let lock = NSLock()
    private var attempts = 0
    private let firstStatus: Int
    private let emitPartial: Bool

    init(toolCalls: Bool = true, firstStatus: Int = 503, emitPartial: Bool = false) {
        capabilities = ProviderCapabilities(toolCalls: toolCalls)
        self.firstStatus = firstStatus
        self.emitPartial = emitPartial
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.lock(); attempts += 1; let attempt = attempts; lock.unlock()
        return AsyncThrowingStream { continuation in
            if attempt == 1 {
                if emitPartial { continuation.yield(.textDelta("partial")) }
                continuation.finish(throwing: ProviderFailure("http_\(firstStatus)", "fixture failure", statusCode: firstStatus))
            } else {
                continuation.yield(.completed(AssistantTurn(text: "recovered")))
                continuation.finish()
            }
        }
    }
}

private final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let id = "fake"
    private let lock = NSLock()
    private var turns: [AssistantTurn]
    init(_ turns: [AssistantTurn]) { self.turns = turns }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.lock(); let turn = turns.isEmpty ? AssistantTurn(text: "fallback") : turns.removeFirst(); lock.unlock()
        return AsyncThrowingStream { continuation in
            if !turn.text.isEmpty { continuation.yield(.textDelta(turn.text)) }
            continuation.yield(.completed(turn)); continuation.finish()
        }
    }
}

private final class ContextCompactionProvider: ModelProvider, @unchecked Sendable {
    let id = "context-fixture"
    private let lock = NSLock()
    private var recordedRequests: [ModelRequest] = []
    var requests: [ModelRequest] { lock.lock(); defer { lock.unlock() }; return recordedRequests }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.lock(); recordedRequests.append(request); lock.unlock()
        let isSummary = request.messages.first?.text.contains("Summarize the earlier conversation") == true
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(AssistantTurn(text: isSummary ? "Preserve the user goal and key decisions." : "final")))
            continuation.finish()
        }
    }
}

final class AgentLoopTests: XCTestCase {
    func testAutomaticallyCompactsOldContextAndPersistsPiCompactionEntry() async throws {
        let provider = ContextCompactionProvider()
        let store = InMemorySessionStore()
        var session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        for index in 0..<6 {
            session = try await store.append(ConversationMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "Earlier conversation item \(index): " + String(repeating: "context ", count: 20)), to: session)
        }
        let agent = Agent(provider: provider, store: store, session: session,
            options: RuntimeOptions(model: ModelDescriptor(id: "context-fixture", providerID: provider.id, contextWindow: 120),
                                    contextCompactionPolicy: .init(triggerRatio: 0.4, targetRatio: 0.2, recentMessagesToKeep: 2)),
            tools: [])
        for await _ in await agent.events(for: "new question") {}

        let requests = provider.requests
        XCTAssertEqual(requests.count, 2, "One summarization request should precede the user turn")
        XCTAssertTrue(requests[0].messages.first?.text.contains("Summarize the earlier conversation") == true)
        XCTAssertTrue(requests[1].messages.contains { $0.text.contains("Preserve the user goal and key decisions") })
        XCTAssertFalse(requests[1].messages.contains { $0.text.contains("Earlier conversation item 0") })
        let persisted = await agent.currentMessages()
        XCTAssertTrue(persisted.contains { $0.text.contains("Summary of earlier conversation") })
        XCTAssertTrue(persisted.contains { $0.text == "Earlier conversation item 5: " + String(repeating: "context ", count: 20) })
    }

    func testReplacesToolsByMCPServerPrefixForSubsequentTurns() async throws {
        let provider = ContextCompactionProvider()
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let oldTool = AgentTool(declaration: ToolDeclaration(name: "mcp_demo_old", description: "old", inputSchema: .object(["type": .string("object")]))) { _, _, _ in ToolResult(text: "old") }
        let newTool = AgentTool(declaration: ToolDeclaration(name: "mcp_demo_new", description: "new", inputSchema: .object(["type": .string("object")]))) { _, _, _ in ToolResult(text: "new") }
        let agent = Agent(provider: provider, store: store, session: session,
            options: RuntimeOptions(model: ModelDescriptor(id: "context-fixture", providerID: provider.id)), tools: [oldTool])
        await agent.replaceTools(withPrefix: "mcp_demo_", using: [newTool])
        for await _ in await agent.events(for: "inspect tools") {}
        XCTAssertEqual(provider.requests.last?.tools.map(\.name), ["mcp_demo_new"])
    }

    func testRunsToolCallThenContinuesToFinalResponse() async throws {
        let provider = ScriptedProvider([
            AssistantTurn(toolCalls: [ToolCall(id: "call-1", name: "echo", arguments: .object(["value": .string("ok")]))], stopReason: .toolUse),
            AssistantTurn(text: "done")
        ])
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let declaration = ToolDeclaration(name: "echo", description: "Echo one value", inputSchema: .object([
            "type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])]),
            "required": .array([.string("value")]), "additionalProperties": .bool(false)
        ]))
        let tool = AgentTool(declaration: declaration) { _, args, _ in ToolResult(text: args.objectValue?["value"]?.stringValue ?? "missing") }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "fake", providerID: "fake"), maximumTurns: 4),
                          tools: [tool])
        var events: [AgentEvent] = []
        for await event in await agent.events(for: "start") { events.append(event) }
        XCTAssertTrue(events.contains { if case .toolEnd = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .agentSettled(_) = $0 { return true }; return false })
        let roles = await agent.currentMessages().map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .toolResult, .assistant])
    }

    func testRejectsInvalidToolArgumentsBeforeExecution() async throws {
        let provider = ScriptedProvider([
            AssistantTurn(toolCalls: [ToolCall(id: "call-1", name: "echo", arguments: .object(["unexpected": .string("x")]))], stopReason: .toolUse),
            AssistantTurn(text: "handled")
        ])
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let declaration = ToolDeclaration(name: "echo", description: "", inputSchema: .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([]), "additionalProperties": .bool(false)
        ]))
        let tool = AgentTool(declaration: declaration) { _, _, _ in XCTFail("Invalid call must not execute"); return ToolResult(text: "bad") }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "fake", providerID: "fake"), maximumTurns: 3),
                          tools: [tool])
        var events: [AgentEvent] = []
        for await event in await agent.events(for: "start") { events.append(event) }
        XCTAssertTrue(events.contains { if case .toolEnd(_, let result) = $0 { return result.isError }; return false })
    }

    func testReadOnlyPermissionPolicyBlocksShellToolBeforeExecution() async throws {
        let provider = ScriptedProvider([
            AssistantTurn(toolCalls: [ToolCall(id: "call-shell", name: "shell", arguments: .object([:]))], stopReason: .toolUse),
            AssistantTurn(text: "handled")
        ])
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let tool = AgentTool(declaration: ToolDeclaration(name: "shell", description: "", inputSchema: .object(["type": .string("object")])),
                             permission: .shell) { _, _, _ in
            XCTFail("Denied shell tool must not execute")
            return ToolResult(text: "unexpected")
        }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "fake", providerID: "fake"), maximumTurns: 3),
                          tools: [tool], permissionPolicy: .readOnly)
        var results: [ToolResult] = []
        for await event in await agent.events(for: "inspect only") {
            if case .toolEnd(_, let result) = event { results.append(result) }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].text.contains("requires shell permission"))
    }

    func testAskPolicyEmitsRequestAndAllowsOnlyAfterApproval() async throws {
        let provider = ScriptedProvider([
            AssistantTurn(toolCalls: [ToolCall(id: "call-write", name: "write", arguments: .object(["value": .string("ok")]))], stopReason: .toolUse),
            AssistantTurn(text: "finished")
        ])
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let schema = JSONValue.object(["type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])]), "required": .array([.string("value")])])
        let tool = AgentTool(declaration: ToolDeclaration(name: "write", description: "", inputSchema: schema), permission: .workspaceWrite) { _, _, _ in
            ToolResult(text: "written")
        }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "fake", providerID: "fake"), maximumTurns: 3),
                          tools: [tool], permissionPolicy: .ask,
                          permissionHandler: { _, _ in .allowOnce })
        var events: [AgentEvent] = []
        for await event in await agent.events(for: "write") { events.append(event) }
        XCTAssertTrue(events.contains { if case .permissionRequest(let request) = $0 { return request.toolName == "write" && request.permission == .workspaceWrite }; return false })
        XCTAssertTrue(events.contains { if case .toolEnd(_, let result) = $0 { return result.text == "written" && !result.isError }; return false })
    }
    func testSessionGrantAllowsSameExactCallWithoutAskingAgain() async throws {
        let call = ToolCall(id: "repeat", name: "write", arguments: .object(["value": .string("approved")]))
        let provider = ScriptedProvider([
            AssistantTurn(toolCalls: [call, call], stopReason: .toolUse),
            AssistantTurn(text: "finished")
        ])
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let schema = JSONValue.object(["type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])])])
        let counter = PermissionTestCounter()
        let tool = AgentTool(declaration: ToolDeclaration(name: "write", description: "", inputSchema: schema), permission: .workspaceWrite) { _, _, _ in
            await counter.recordExecution()
            return ToolResult(text: "done")
        }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "fake", providerID: "fake"), maximumTurns: 3),
                          tools: [tool], permissionPolicy: .ask,
                          permissionHandler: { _, _ in
                              await counter.recordApproval()
                              return .allowForSession
                          })
        for await _ in await agent.events(for: "run repeat tool") {}
        let counts = await counter.values()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 2)
    }

    func testAgentDispatchesNamespacedPluginCommand() async throws {
        let provider = ScriptedProvider([AssistantTurn(text: "unused")])
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let command = AgentCommand(name: "fixture:echo", description: "Echo args") { arguments, _ in
            arguments.joined(separator: "|")
        }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "fake", providerID: "fake")),
                          tools: [], commands: [command.name: command])
        let result = try await agent.executeCommand("fixture:echo", arguments: ["one", "two"])
        XCTAssertEqual(result, "one|two")
        let unknown = try await agent.executeCommand("missing:command", arguments: [])
        XCTAssertNil(unknown)
    }

    func testRetriesRetryableProviderFailureBeforeAnyStreamContent() async throws {
        let provider = RetryScriptProvider()
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "retry-fixture", providerID: provider.id),
                                                  providerRetryPolicy: .init(maximumRetries: 1, baseDelayMilliseconds: 0)),
                          tools: [])
        var recovered = false
        for await event in await agent.events(for: "retry") {
            if case .messageEnd(let message) = event, message.role == .assistant, message.text == "recovered" { recovered = true }
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(provider.callCount, 2)
    }

    func testDoesNotRetryAfterPartialOutputOrOnClientError() async throws {
        let provider = RetryScriptProvider(firstStatus: 503, emitPartial: true)
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "retry-fixture", providerID: provider.id),
                                                  providerRetryPolicy: .init(maximumRetries: 2, baseDelayMilliseconds: 0)),
                          tools: [])
        for await _ in await agent.events(for: "do not duplicate partial text") {}
        XCTAssertEqual(provider.callCount, 1)
    }

    func testRejectsToolCallsWhenProviderReportsNoToolSupport() async throws {
        let provider = RetryScriptProvider(toolCalls: true)
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let tool = AgentTool(declaration: ToolDeclaration(name: "noop", description: "", inputSchema: .object(["type": .string("object")]))) { _, _, _ in ToolResult(text: "unused") }
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "retry-fixture", providerID: provider.id, supportsTools: false)),
                          tools: [tool])
        var failure: String?
        for await event in await agent.events(for: "capability check") {
            if case .failed(_, let message) = event { failure = message }
        }
        XCTAssertTrue(failure?.contains("does not support tool calls") == true)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testDoesNotRetryAuthenticationFailure() async throws {
        let provider = RetryScriptProvider(firstStatus: 401)
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let agent = Agent(provider: provider, store: store, session: session,
                          options: RuntimeOptions(model: ModelDescriptor(id: "retry-fixture", providerID: provider.id),
                                                  providerRetryPolicy: .init(maximumRetries: 2, baseDelayMilliseconds: 0)),
                          tools: [])
        for await _ in await agent.events(for: "credentials are invalid") {}
        XCTAssertEqual(provider.callCount, 1)
    }

}
