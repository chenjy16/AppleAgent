import Foundation
import XCTest
import PiTypes
import PiSession

final class JSONLSessionStoreTests: XCTestCase {
    func testCreatesPiV3SessionAndRestoresActiveBranch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(directory: directory)
        var session = try await store.create(cwd: URL(fileURLWithPath: "/workspace"), metadata: .init())
        let first = ConversationMessage(id: "root", role: .user, text: "hello")
        session = try await store.append(first, to: session)
        let assistant = ConversationMessage(id: "answer", role: .assistant, text: "world")
        session = try await store.append(assistant, to: session)
        let alternate = try await store.setActiveLeaf("root", in: session)
        let branch = ConversationMessage(id: "branch", role: .user, text: "alternate")
        _ = try await store.append(branch, to: alternate)

        let lines = try String(contentsOf: directory.appendingPathComponent("\(session.id).jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(header["type"] as? String, "session")
        XCTAssertEqual(header["version"] as? Int, 3)
        XCTAssertEqual(session.activeMessages.map(\.text), ["hello", "world"])
        XCTAssertEqual(alternate.activeMessages.map(\.text), ["hello"])
    }

    func testLoadsPiV3SessionFixtureWithOpaqueEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repositoryRoot.appendingPathComponent("Fixtures/PiCompatibility/current/session-v3.jsonl")
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("fixture-v3.jsonl"))
        let loaded = try await JSONLSessionStore(directory: directory).load(id: "fixture-v3")
        XCTAssertEqual(loaded.activeMessages.map(\.role), [.user, .assistant, .toolResult])
        XCTAssertEqual(loaded.activeMessages.map(\.text), ["Hello", "Hi!", "output"])
        XCTAssertEqual(loaded.entries.last?.rawValue?.objectValue?["customType"]?.stringValue, "fixture")
    }

    func testLoadsLegacyLinearSessionAndContinuesParentChain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: root.appendingPathComponent("Fixtures/PiCompatibility/current/session-v1-linear.jsonl"),
                                         to: directory.appendingPathComponent("fixture-v1.jsonl"))
        let store = JSONLSessionStore(directory: directory)
        var loaded = try await store.load(id: "fixture-v1")
        XCTAssertEqual(loaded.activeMessages.map(\.text), ["first", "second"])
        loaded = try await store.append(ConversationMessage(role: .user, text: "third"), to: loaded)
        let reopened = try await store.load(id: "fixture-v1")
        XCTAssertEqual(reopened.activeMessages.map(\.text), ["first", "second", "third"])
    }

    func testCompactionSummaryReplacesEarlierContextAndKeepsRetainedMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: root.appendingPathComponent("Fixtures/PiCompatibility/current/session-compaction-v3.jsonl"),
                                         to: directory.appendingPathComponent("fixture-compaction.jsonl"))
        let loaded = try await JSONLSessionStore(directory: directory).load(id: "fixture-compaction")
        XCTAssertEqual(loaded.activeMessages.map(\.text), [
            "Summary of earlier conversation:\nThe user asked an old question and received an answer.",
            "Keep this question", "New answer"
        ])
    }

    func testAppendsAndReloadsGeneratedCompactionRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(directory: directory)
        var session = try await store.create(cwd: URL(fileURLWithPath: "/workspace"), metadata: .init())
        session = try await store.append(ConversationMessage(role: .user, text: "old request"), to: session)
        session = try await store.append(ConversationMessage(role: .assistant, text: "old answer"), to: session)
        session = try await store.append(ConversationMessage(role: .user, text: "keep this"), to: session)
        let keptID = try XCTUnwrap(session.activeLeafID)
        session = try await store.appendCompaction(summary: "Earlier request was answered.", firstKeptEntryID: keptID, to: session)
        session = try await store.append(ConversationMessage(role: .assistant, text: "new answer"), to: session)

        let reopened = try await store.load(id: session.id)
        XCTAssertEqual(reopened.activeMessages.map(\.text), [
            "Summary of earlier conversation:\nEarlier request was answered.", "keep this", "new answer"
        ])
        XCTAssertEqual(reopened.entries.last(where: { $0.rawValue?.objectValue?["type"]?.stringValue == "compaction" })?
            .rawValue?.objectValue?["firstKeptEntryId"]?.stringValue, keptID)
    }

    func testRejectsMalformedMiddleRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(directory: directory)
        let session = try await store.create(cwd: URL(fileURLWithPath: "/workspace"), metadata: .init())
        let url = directory.appendingPathComponent("\(session.id).jsonl")
        let original = try String(contentsOf: url, encoding: .utf8)
        try Data((original + "{broken}\n{\"type\":\"custom\",\"id\":\"end\",\"parentId\":null,\"timestamp\":\"2024-01-01T00:00:00.000Z\"}\n").utf8)
            .write(to: url, options: .atomic)
        do {
            _ = try await store.load(id: session.id)
            XCTFail("A malformed middle entry must not be silently discarded")
        } catch let error as SessionStoreError {
            guard case .invalidEntry(line: 2, reason: _) = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testPreservesUnknownEntriesAndIgnoresOnlyTornFinalLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLSessionStore(directory: directory)
        let session = try await store.create(cwd: URL(fileURLWithPath: "/workspace"), metadata: .init())
        let url = directory.appendingPathComponent("\(session.id).jsonl")
        let unknown = #"{"type":"customEntry","id":"opaque","parentId":null,"timestamp":"2024-01-01T00:00:00.000Z","payload":{"keep":true}}"#
        let original = try String(contentsOf: url, encoding: .utf8)
        try Data((original + unknown + "\n{").utf8).write(to: url, options: .atomic)
        let loaded = try await store.load(id: session.id)
        XCTAssertEqual(loaded.entries.first?.rawValue?.objectValue?["payload"]?.objectValue?["keep"]?.boolValue, true)
    }
}
