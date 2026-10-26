import Foundation
import XCTest
import PiTypes
import PiRuntime

final class FilePermissionGrantStoreTests: XCTestCase {
    func testProjectGrantPersistsExactScopedDigestWithoutArgumentsAndCanBeRevoked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grants.json")
        let store = FilePermissionGrantStore(fileURL: file)
        let request = ToolPermissionRequest(toolName: "bash", permission: .shell,
                                            arguments: .object(["command": .string("echo secret-value")]),
                                            sessionID: "session-a", projectPath: root.path)
        let initiallyAllowed = try await store.containsProjectGrant(for: request)
        XCTAssertFalse(initiallyAllowed)
        try await store.saveProjectGrant(for: request)
        try await store.saveProjectGrant(for: request)
        let grantDocument = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(grantDocument.components(separatedBy: "argumentsDigest").count - 1, 1)
        let reopened = FilePermissionGrantStore(fileURL: file)
        let restoredAllowed = try await reopened.containsProjectGrant(for: request)
        XCTAssertTrue(restoredAllowed)
        var differentArguments = request
        differentArguments.arguments = .object(["command": .string("echo another-value")])
        let differentCallAllowed = try await reopened.containsProjectGrant(for: differentArguments)
        XCTAssertFalse(differentCallAllowed)
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret-value"))
        try await reopened.revokeProjectGrants(for: root.path)
        let afterRevoke = try await FilePermissionGrantStore(fileURL: file).containsProjectGrant(for: request)
        XCTAssertFalse(afterRevoke)
    }


    func testCredentialReferenceResolverExpandsEnvironmentAndPreservesLiterals() throws {
        let result = try CredentialReferenceResolver.resolve([
            "Authorization": "Bearer ${ENV:MCP_TOKEN}",
            "X-Static": "literal"
        ], environment: ["MCP_TOKEN": "secret-token"])
        XCTAssertEqual(result["Authorization"], "Bearer secret-token")
        XCTAssertEqual(result["X-Static"], "literal")
    }

    func testProjectGrantNeedsProjectPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FilePermissionGrantStore(fileURL: root.appendingPathComponent("grants.json"))
        let request = ToolPermissionRequest(toolName: "bash", permission: .shell,
                                            arguments: .object([:]), projectPath: nil)
        do {
            try await store.saveProjectGrant(for: request)
            XCTFail("Expected missing project path to fail")
        } catch let error as PermissionGrantStoreError {
            XCTAssertEqual(error.localizedDescription, PermissionGrantStoreError.missingProjectPath.localizedDescription)
        }
    }
    func testSessionGrantIsSharedAcrossAgentsInProcessButBoundToSessionAndArguments() async throws {
        let store = FilePermissionGrantStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let request = ToolPermissionRequest(toolName: "write", permission: .workspaceWrite,
                                            arguments: .object(["path": .string("a.txt")]),
                                            sessionID: "session-a", projectPath: "/tmp/project")
        try await store.saveSessionGrant(for: request)
        let reused = try await store.containsSessionGrant(for: request)
        XCTAssertTrue(reused)
        var otherSession = request
        otherSession.sessionID = "session-b"
        let crossSession = try await store.containsSessionGrant(for: otherSession)
        XCTAssertFalse(crossSession)
        var otherArguments = request
        otherArguments.arguments = .object(["path": .string("b.txt")])
        let changedCall = try await store.containsSessionGrant(for: otherArguments)
        XCTAssertFalse(changedCall)
    }

    func testCredentialReferenceRejectsMissingSecretsWithoutReturningSecretData() {
        XCTAssertThrowsError(try CredentialReferenceResolver.resolve(["Authorization": "${ENV:MISSING_TOKEN}"], environment: [:]))
    }

}
