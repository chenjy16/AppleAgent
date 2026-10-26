import Foundation
import XCTest
import PiTypes
import PiProviders
import PiSession
import PiAgentCore
import PiRPC

final class RPCHostTests: XCTestCase {
    func testUsesLFOnlyFramingAndCorrelatesResponses() async throws {
        let input = Pipe(); let output = Pipe()
        let factory: RPCHost.AgentFactory = { _, _, _, _, _ in throw RPCFixtureError.unexpectedAgentCreation }
        let host = RPCHost(output: output.fileHandleForWriting, makeAgent: factory)
        let task = Task { await host.run(input: input.fileHandleForReading) }
        let separator = "\u{2028}"
        let commands = "{\"id\":\"c1\",\"type\":\"unknown\",\"message\":\"left\(separator)right\"}\n{\"id\":\"c2\",\"type\":\"permission_response\",\"requestId\":\"missing\",\"approved\":true}\n{\"id\":\"c3\",\"type\":\"shutdown\"}\n"
        try input.fileHandleForWriting.write(contentsOf: Data(commands.utf8))
        try input.fileHandleForWriting.close()
        await task.value
        try output.fileHandleForWriting.close()
        let outputData = try XCTUnwrap(output.fileHandleForReading.readToEnd())
        let lines = try XCTUnwrap(String(data: outputData, encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["id"] as? String, "c1")
        XCTAssertEqual(first["command"] as? String, "unknown")
        XCTAssertEqual(first["success"] as? Bool, false)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["id"] as? String, "c2")
        XCTAssertEqual(second["success"] as? Bool, false)
        XCTAssertEqual(second["command"] as? String, "permission_response")
        let third = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        XCTAssertEqual(third["id"] as? String, "c3")
        XCTAssertEqual(third["success"] as? Bool, true)
    }
    func testDispatchesPluginCommandThroughRPC() async throws {
        let input = Pipe(); let output = Pipe()
        let provider = RPCCommandProvider()
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let command = AgentCommand(name: "fixture:echo", description: "Echo arguments") { args, _ in args.joined(separator: " ") }
        let factory: RPCHost.AgentFactory = { _, _, _, _, _ in
            Agent(provider: provider, store: store, session: session,
                  options: RuntimeOptions(model: ModelDescriptor(id: "fixture", providerID: "fixture")),
                  tools: [], commands: [command.name: command])
        }
        let host = RPCHost(output: output.fileHandleForWriting, makeAgent: factory)
        let task = Task { await host.run(input: input.fileHandleForReading) }
        let commands = "{\"id\":\"cmd\",\"type\":\"execute_command\",\"command\":\"fixture:echo\",\"args\":[\"one\",\"two\"]}\n{\"id\":\"stop\",\"type\":\"shutdown\"}\n"
        try input.fileHandleForWriting.write(contentsOf: Data(commands.utf8))
        try input.fileHandleForWriting.close()
        await task.value
        try output.fileHandleForWriting.close()
        let outputData = try XCTUnwrap(output.fileHandleForReading.readToEnd())
        let lines = try XCTUnwrap(String(data: outputData, encoding: .utf8)).split(separator: "\n")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["id"] as? String, "cmd")
        XCTAssertEqual(first["success"] as? Bool, true)
        let data = try XCTUnwrap(first["data"] as? [String: Any])
        XCTAssertEqual(data["output"] as? String, "one two")
    }

    func testSteerPreemptsAndFollowUpsRemainFIFO() async throws {
        let input = Pipe(); let output = Pipe()
        let provider = RPCSlowProvider()
        let store = InMemorySessionStore()
        let session = try await store.create(cwd: URL(fileURLWithPath: "/tmp"), metadata: .init())
        let factory: RPCHost.AgentFactory = { _, _, _, _, _ in
            Agent(provider: provider, store: store, session: session,
                  options: RuntimeOptions(model: ModelDescriptor(id: "fixture", providerID: "fixture")), tools: [])
        }
        let host = RPCHost(output: output.fileHandleForWriting, makeAgent: factory)
        let task = Task { await host.run(input: input.fileHandleForReading) }
        let requests = """
        {"id":"p1","type":"prompt","message":"first"}
        {"id":"p2","type":"follow_up","message":"second"}
        {"id":"p3","type":"steer","message":"steering"}
        {"id":"p4","type":"follow_up","message":"third"}
        """
        try input.fileHandleForWriting.write(contentsOf: Data((requests + "\n").utf8))
        try await Task.sleep(for: .milliseconds(900))
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":\"stop\",\"type\":\"shutdown\"}\n".utf8))
        try input.fileHandleForWriting.close()
        await task.value
        try output.fileHandleForWriting.close()

        let outputData = try XCTUnwrap(output.fileHandleForReading.readToEnd())
        let outputText = try XCTUnwrap(String(data: outputData, encoding: .utf8))
        let records = try outputText.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let userPrompts = records.compactMap { record -> String? in
            guard record["type"] as? String == "message_start",
                  let message = record["message"] as? [String: Any], message["role"] as? String == "user" else { return nil }
            return message["content"] as? String
        }
        XCTAssertEqual(userPrompts, ["first", "steering", "second", "third"])
        let queuedResponses = records.compactMap { record -> String? in
            guard record["type"] as? String == "response",
                  let data = record["data"] as? [String: Any] else { return nil }
            return data["disposition"] as? String
        }
        XCTAssertEqual(queuedResponses, ["started", "queued", "steering", "queued"])
    }

}

private enum RPCFixtureError: Error { case unexpectedAgentCreation }

private struct RPCCommandProvider: ModelProvider {
    let id = "fixture"
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(AssistantTurn(text: "unused")))
            continuation.finish()
        }
    }
}

private struct RPCSlowProvider: ModelProvider {
    let id = "fixture"
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                continuation.yield(.completed(AssistantTurn(text: "reply")))
                continuation.finish()
            }
        }
    }
}
