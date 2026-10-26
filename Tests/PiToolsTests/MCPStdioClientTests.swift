import Foundation
import XCTest
import PiTypes
import PiAgentCore
import PiTools

final class MCPStdioClientTests: XCTestCase {
    func testDiscoversAndCallsToolOverMCPStdio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("mcp-server.sh")
        let cancellationLog = directory.appendingPathComponent("cancel-notifications.jsonl")
        let source = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in *'notifications'*'cancelled'*) printf '%s\n' "$line" >> "$CANCEL_LOG" ;; esac
          case "$line" in
            *'"method":"initialize"'*) id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/'); printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}\n' "$id" ;;
            *'"method":"tools'*'list"'*)
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              if printf '%s' "$line" | grep -q '"cursor":"next"'; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo_second","description":"Second page","inputSchema":{"type":"object"}}]}}\n' "$id"
              else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo input","inputSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}],"nextCursor":"next"}}\n' "$id"
              fi ;;

            *'"method":"tools'*'call"'*)
              if printf '%s' "$line" | grep -q '"slow":true'; then :
              else
                id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
                printf '{"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}}\n'
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"fixture result"}],"isError":false}}\n' "$id"
              fi ;;
          esac
        done
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = try MCPStdioClient.connect(name: "fixture", configuration: .init(command: script.path, env: ["CANCEL_LOG": cancellationLog.path]), responseTimeout: 3)
        let tools: [AgentTool]
        do { tools = try client.agentTools() }
        catch { return XCTFail("agentTools failed: \(error)") }
        var notifications = client.notifications().makeAsyncIterator()
        XCTAssertEqual(tools.map(\.declaration.name), ["mcp_fixture_echo", "mcp_fixture_echo_second"])
        let context = ToolContext(workingDirectory: directory, cancellation: CancellationToken())
        let result: ToolResult
        do { result = try await tools[0].execute("call-1", .object(["value": .string("hello")]), context) }
        catch { return XCTFail("Tool call failed: \(error)") }
        XCTAssertEqual(result.text, "fixture result")
        XCTAssertFalse(result.isError)
        let notification = await notifications.next()
        XCTAssertEqual(notification?.method, "notifications/resources/list_changed")

        let cancellation = CancellationToken()
        let cancellationContext = ToolContext(workingDirectory: directory, cancellation: cancellation)
        let task = Task { try await tools[0].execute("slow-call", .object(["slow": .bool(true)]), cancellationContext) }
        try await Task.sleep(for: .milliseconds(100))
        cancellation.cancel()
        do { _ = try await task.value; XCTFail("Cancelled stdio call should throw") }
        catch is CancellationError {}
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: cancellationLog.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let cancellationRecord = try? String(contentsOf: cancellationLog, encoding: .utf8) else {
            return XCTFail("No cancellation notification was received by the fixture server")
        }
        XCTAssertTrue(cancellationRecord.contains("cancelled"))
    }
}
