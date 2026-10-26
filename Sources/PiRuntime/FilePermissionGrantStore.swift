import Foundation
import CryptoKit
import PiTypes
import PiAgentCore

/// User-level persistent grants. Only a SHA-256 digest of canonical tool arguments is stored.
public actor FilePermissionGrantStore: ToolPermissionGrantStore {
    private struct Grant: Codable, Sendable, Equatable {
        var projectPath: String
        var toolName: String
        var permission: ToolPermission
        var argumentsDigest: String
        var createdAt: Date
    }

    private struct Document: Codable, Sendable {
        var version: Int
        var grants: [Grant]
    }

    private let fileURL: URL
    private var sessionGrants: Set<String> = []

    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".apple-agent/permission-grants.json")) {
        self.fileURL = fileURL
    }

    public func containsSessionGrant(for request: ToolPermissionRequest) async throws -> Bool {
        guard let key = try sessionGrantKey(for: request) else { return false }
        return sessionGrants.contains(key)
    }

    public func saveSessionGrant(for request: ToolPermissionRequest) async throws {
        guard let key = try sessionGrantKey(for: request) else { return }
        sessionGrants.insert(key)
    }

    public func containsProjectGrant(for request: ToolPermissionRequest) async throws -> Bool {
        guard let grant = try makeGrant(request) else { return false }
        let document = try load()
        return document.grants.contains {
            $0.projectPath == grant.projectPath && $0.toolName == grant.toolName
                && $0.permission == grant.permission && $0.argumentsDigest == grant.argumentsDigest
        }
    }

    public func saveProjectGrant(for request: ToolPermissionRequest) async throws {
        guard let grant = try makeGrant(request) else {
            throw PermissionGrantStoreError.missingProjectPath
        }
        var document = try load()
        guard !document.grants.contains(where: {
            $0.projectPath == grant.projectPath && $0.toolName == grant.toolName
                && $0.permission == grant.permission && $0.argumentsDigest == grant.argumentsDigest
        }) else { return }
        document.grants.append(grant)
        try persist(document)
    }

    public func revokeProjectGrants(for projectPath: String) async throws {
        let canonicalPath = Self.canonicalPath(projectPath)
        var document = try load()
        document.grants.removeAll { $0.projectPath == canonicalPath }
        try persist(document)
    }

    private func makeGrant(_ request: ToolPermissionRequest) throws -> Grant? {
        guard let projectPath = request.projectPath else { return nil }
        return Grant(projectPath: Self.canonicalPath(projectPath), toolName: request.toolName,
                     permission: request.permission, argumentsDigest: try Self.argumentsDigest(request.arguments), createdAt: .now)
    }

    private func sessionGrantKey(for request: ToolPermissionRequest) throws -> String? {
        guard let sessionID = request.sessionID else { return nil }
        return [sessionID, request.toolName, request.permission.rawValue,
                try Self.argumentsDigest(request.arguments)].joined(separator: "\u{0}")
    }

    private static func argumentsDigest(_ arguments: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let argumentBytes = try encoder.encode(arguments)
        return SHA256.hash(data: argumentBytes).map { String(format: "%02x", $0) }.joined()
    }

    private func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Document(version: 1, grants: [])
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw PermissionGrantStoreError.unsupportedVersion(document.version) }
            return document
        } catch let error as PermissionGrantStoreError {
            throw error
        } catch {
            throw PermissionGrantStoreError.corruptFile(fileURL.path, error.localizedDescription)
        }
    }

    private func persist(_ document: Document) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public enum PermissionGrantStoreError: Error, LocalizedError {
    case missingProjectPath
    case unsupportedVersion(Int)
    case corruptFile(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingProjectPath: "Cannot save a project permission without a project path"
        case .unsupportedVersion(let version): "Unsupported permission grant file version: \(version)"
        case .corruptFile(let path, let message): "Permission grant file is unreadable at \(path): \(message)"
        }
    }
}
