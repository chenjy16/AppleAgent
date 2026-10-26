import Foundation
import PiTypes

public struct SessionMetadata: Sendable {
    public var parentSession: String?
    public init(parentSession: String? = nil) { self.parentSession = parentSession }
}

public struct SessionSummary: Sendable, Identifiable {
    public var id: String
    public var cwd: String
    public var updatedAt: Date
    public var messageCount: Int
}

public struct SessionSnapshot: Sendable {
    public var id: String
    public var cwd: String
    public var entries: [SessionEntry]
    public var activeLeafID: String?
    /// The original header, including fields unknown to Apple Agent.
    public var header: JSONValue
    public var fileURL: URL?

    public init(id: String, cwd: String, entries: [SessionEntry] = [], activeLeafID: String? = nil,
                header: JSONValue = .object([:]), fileURL: URL? = nil) {
        self.id = id; self.cwd = cwd; self.entries = entries; self.activeLeafID = activeLeafID
        self.header = header; self.fileURL = fileURL
    }

    public var activeMessages: [ConversationMessage] {
        let index = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var path: [SessionEntry] = []
        var current = activeLeafID
        var visited = Set<String>()
        while let id = current, let entry = index[id], visited.insert(id).inserted {
            path.append(entry); current = entry.parentID
        }
        path.reverse()
        var selected = path
        if let compactionIndex = path.lastIndex(where: { $0.rawValue?.objectValue?["type"]?.stringValue == "compaction" }),
           let raw = path[compactionIndex].rawValue?.objectValue {
            var compacted: [SessionEntry] = []
            if let checkpoint = raw["systemMessage"],
               let message = JSONLSessionStore.decodeMessage(checkpoint, entryID: path[compactionIndex].id + "-system") {
                compacted.append(SessionEntry(id: message.id, parentID: nil, timestamp: message.timestamp, message: message))
            }
            if let summary = raw["summary"]?.stringValue, !summary.isEmpty {
                compacted.append(SessionEntry(id: path[compactionIndex].id + "-summary", parentID: nil,
                                              timestamp: path[compactionIndex].timestamp,
                                              message: ConversationMessage(id: path[compactionIndex].id + "-summary",
                                                  role: .assistant, timestamp: path[compactionIndex].timestamp,
                                                  text: "Summary of earlier conversation:\n\(summary)")))
            }
            if let firstKeptID = raw["firstKeptEntryId"]?.stringValue,
               let firstKeptIndex = path.firstIndex(where: { $0.id == firstKeptID }), firstKeptIndex < compactionIndex {
                compacted += path[firstKeptIndex..<compactionIndex].filter {
                    $0.rawValue?.objectValue?["type"]?.stringValue != "system"
                }
            }
            compacted += path.dropFirst(compactionIndex + 1)
            selected = compacted
        }
        var edits: [String: JSONValue] = [:]
        for entry in path where entry.rawValue?.objectValue?["type"]?.stringValue == "context_edit" {
            guard let raw = entry.rawValue?.objectValue,
                  let targetID = raw["targetId"]?.stringValue,
                  let replacement = raw["replacement"] else { continue }
            edits[targetID] = replacement
        }
        return selected.compactMap { entry in
            if entry.rawValue?.objectValue?["type"]?.stringValue == "message" { return entry.message }
            guard let raw = entry.rawValue?.objectValue else { return entry.message }
            switch raw["type"]?.stringValue {
            case "branch_summary":
                guard let summary = raw["summary"]?.stringValue else { return nil }
                return ConversationMessage(id: entry.id, role: .assistant, timestamp: entry.timestamp,
                                           text: "Summary of alternate branch:\n\(summary)")
            case "custom_message":
                guard let content = raw["content"] else { return nil }
                return ConversationMessage(id: entry.id, role: .custom, timestamp: entry.timestamp,
                                           text: content.stringValue ?? Self.text(from: content))
            default: return entry.message
            }
        }.compactMap { message in
            guard let replacement = edits[message.id] else { return message }
            if case .null = replacement { return nil }
            var updated = message
            if let text = replacement.stringValue { updated.text = text }
            else if case .array = replacement { updated.text = Self.text(from: replacement) }
            return updated
        }
    }

    private static func text(from value: JSONValue) -> String {
        guard case .array(let blocks) = value else { return "" }
        return blocks.compactMap { block -> String? in
            guard block.objectValue?["type"]?.stringValue == "text" else { return nil }
            return block.objectValue?["text"]?.stringValue
        }.joined()
    }
}

public struct SessionEntry: Sendable, Identifiable {
    public var id: String
    public var parentID: String?
    public var timestamp: Date
    public var message: ConversationMessage?
    /// Original record retained so compaction and other future Pi entries survive a round trip.
    public var rawValue: JSONValue?

    public init(id: String, parentID: String?, timestamp: Date, message: ConversationMessage? = nil,
                rawValue: JSONValue? = nil) {
        self.id = id; self.parentID = parentID; self.timestamp = timestamp; self.message = message; self.rawValue = rawValue
    }
}

public protocol SessionStore: Sendable {
    func create(cwd: URL, metadata: SessionMetadata) async throws -> SessionSnapshot
    func load(id: String) async throws -> SessionSnapshot
    func load(fileURL: URL) async throws -> SessionSnapshot
    func append(_ message: ConversationMessage, to snapshot: SessionSnapshot) async throws -> SessionSnapshot
    func appendCompaction(summary: String, firstKeptEntryID: String, to snapshot: SessionSnapshot) async throws -> SessionSnapshot
    func setActiveLeaf(_ entryID: String, in snapshot: SessionSnapshot) async throws -> SessionSnapshot
    func list(cwd: URL, limit: Int?) async throws -> [SessionSummary]
}

public actor JSONLSessionStore: SessionStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func create(cwd: URL, metadata: SessionMetadata = SessionMetadata()) throws -> SessionSnapshot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let timestamp = Self.formatDate(.now)
        var header: [String: JSONValue] = [
            "type": .string("session"), "version": .number(3), "id": .string(id),
            "timestamp": .string(timestamp), "cwd": .string(cwd.standardizedFileURL.path)
        ]
        if let parent = metadata.parentSession { header["parentSession"] = .string(parent) }
        let value = JSONValue.object(header)
        try appendLine(value, to: fileURL(id))
        return SessionSnapshot(id: id, cwd: cwd.standardizedFileURL.path, header: value, fileURL: fileURL(id))
    }

    public func load(id: String) throws -> SessionSnapshot {
        guard Self.isSafeSessionID(id) else { throw SessionStoreError.invalidID }
        return try load(fileURL: fileURL(id))
    }

    public func load(fileURL url: URL) throws -> SessionSnapshot {
        guard url.pathExtension == "jsonl", url.isFileURL else { throw SessionStoreError.invalidID }
        let url = url.standardizedFileURL
        let data = try Data(contentsOf: url)
        let hasFinalLF = data.last == 0x0A
        let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var lines = rawLines.map { Data($0) }
        if hasFinalLF, lines.last?.isEmpty == true { lines.removeLast() }
        if !hasFinalLF, lines.last?.isEmpty == true { lines.removeLast() }
        guard let headerLine = lines.first else { throw SessionStoreError.invalidHeader }
        let header = try Self.decodeObject(headerLine, lineNumber: 1)
        guard header["type"]?.stringValue == "session",
              let storedID = header["id"]?.stringValue else { throw SessionStoreError.invalidHeader }
        let cwd = header["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
        var entries: [SessionEntry] = []
        let version = header["version"].flatMap { value -> Int? in
            if case .number(let number) = value { return Int(number) }; return nil
        } ?? 1
        var previousLegacyID: String?
        for (offset, line) in lines.dropFirst().enumerated() {
            if line.isEmpty { continue }
            do {
                let record = try Self.decodeObject(line, lineNumber: offset + 2)
                guard let type = record["type"]?.stringValue else {
                    throw SessionStoreError.invalidEntry(line: offset + 2, reason: "missing type")
                }
                let lineNumber = offset + 2
                let id = record["id"]?.stringValue ?? (version == 1 ? "legacy-\(lineNumber)" : UUID().uuidString.lowercased())
                let parentID = record["parentId"]?.stringValue ?? (version == 1 ? previousLegacyID : nil)
                previousLegacyID = id
                let timestamp = record["timestamp"]?.stringValue.flatMap(Self.parseDate) ?? .now
                let message = type == "message" ? Self.decodeMessage(record["message"], entryID: id) : nil
                entries.append(SessionEntry(id: id, parentID: parentID, timestamp: timestamp,
                                            message: message, rawValue: .object(record)))
            } catch {
                let isTornFinalRecord = offset == lines.count - 2 && !hasFinalLF
                if isTornFinalRecord { break }
                throw error
            }
        }
        return SessionSnapshot(id: storedID, cwd: cwd, entries: entries, activeLeafID: entries.last?.id,
                               header: .object(header), fileURL: url)
    }

    public func append(_ message: ConversationMessage, to snapshot: SessionSnapshot) throws -> SessionSnapshot {
        guard Self.isSafeSessionID(snapshot.id) else { throw SessionStoreError.invalidID }
        let entryID = message.id
        var record: [String: JSONValue] = [
            "type": .string("message"), "id": .string(entryID),
            "timestamp": .string(Self.formatDate(message.timestamp)),
            "message": Self.encodeMessage(message)
        ]
        record["parentId"] = snapshot.activeLeafID.map(JSONValue.string) ?? .null
        let destination = snapshot.fileURL ?? fileURL(snapshot.id)
        try appendLine(.object(record), to: destination)
        var updated = snapshot
        updated.entries.append(SessionEntry(id: entryID, parentID: snapshot.activeLeafID, timestamp: message.timestamp,
                                            message: message, rawValue: .object(record)))
        updated.activeLeafID = entryID
        updated.fileURL = destination
        return updated
    }

    public func appendCompaction(summary: String, firstKeptEntryID: String, to snapshot: SessionSnapshot) throws -> SessionSnapshot {
        guard Self.isSafeSessionID(snapshot.id), snapshot.entries.contains(where: { $0.id == firstKeptEntryID }) else {
            throw SessionStoreError.entryNotFound(firstKeptEntryID)
        }
        let id = UUID().uuidString.lowercased()
        let timestamp = Date()
        let record: [String: JSONValue] = [
            "type": .string("compaction"), "id": .string(id),
            "parentId": snapshot.activeLeafID.map(JSONValue.string) ?? .null,
            "timestamp": .string(Self.formatDate(timestamp)), "summary": .string(summary),
            "firstKeptEntryId": .string(firstKeptEntryID)
        ]
        let destination = snapshot.fileURL ?? fileURL(snapshot.id)
        try appendLine(.object(record), to: destination)
        var updated = snapshot
        updated.entries.append(SessionEntry(id: id, parentID: snapshot.activeLeafID, timestamp: timestamp,
                                            rawValue: .object(record)))
        updated.activeLeafID = id
        updated.fileURL = destination
        return updated
    }

    public func setActiveLeaf(_ entryID: String, in snapshot: SessionSnapshot) throws -> SessionSnapshot {
        guard entryID.isEmpty || snapshot.entries.contains(where: { $0.id == entryID }) else {
            throw SessionStoreError.entryNotFound(entryID)
        }
        var updated = snapshot
        updated.activeLeafID = entryID.isEmpty ? nil : entryID
        return updated
    }

    public func list(cwd: URL, limit: Int? = nil) throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }
        let desiredCWD = cwd.standardizedFileURL.path
        var summaries: [SessionSummary] = []
        for url in urls {
            guard let snapshot = try? load(id: url.deletingPathExtension().lastPathComponent), snapshot.cwd == desiredCWD else { continue }
            let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            summaries.append(SessionSummary(id: snapshot.id, cwd: snapshot.cwd, updatedAt: updated,
                                            messageCount: snapshot.entries.filter { $0.message != nil }.count))
        }
        let ordered = summaries.sorted { $0.updatedAt > $1.updatedAt }
        return limit.map { Array(ordered.prefix(max(0, $0))) } ?? ordered
    }

    fileprivate static func formatDate(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    fileprivate static func parseDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }

    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).jsonl") }

    private func appendLine(_ value: JSONValue, to url: URL) throws {
        let data = value.encodedData
        guard case .object = value else { throw SessionStoreError.encoding }
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0A]))
            try handle.synchronize()
        } else {
            try (data + Data([0x0A])).write(to: url, options: .atomic)
        }
    }

    private static func decodeObject(_ data: Data, lineNumber: Int) throws -> [String: JSONValue] {
        do {
            guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                throw SessionStoreError.invalidEntry(line: lineNumber, reason: "record is not a JSON object")
            }
            return object
        } catch let error as SessionStoreError { throw error }
        catch { throw SessionStoreError.invalidEntry(line: lineNumber, reason: error.localizedDescription) }
    }

    private static func encodeMessage(_ message: ConversationMessage) -> JSONValue {
        var fields: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "timestamp": .number(message.timestamp.timeIntervalSince1970 * 1000)
        ]
        if message.role == .assistant {
            var blocks: [JSONValue] = []
            if !message.text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(message.text)])) }
            blocks += message.toolCalls.map { .object(["type": .string("toolCall"), "id": .string($0.id), "name": .string($0.name), "arguments": $0.arguments]) }
            fields["content"] = .array(blocks)
        } else if message.role == .toolResult {
            fields["content"] = .array([.object(["type": .string("text"), "text": .string(message.text)])])
            fields["toolCallId"] = .string(message.toolCallID ?? "")
            fields["toolName"] = .string(message.toolName ?? "unknown")
            fields["isError"] = .bool(message.isError ?? false)
        } else {
            fields["content"] = .string(message.text)
        }
        if let toolCallID = message.toolCallID { fields["toolCallId"] = .string(toolCallID) }
        if let toolName = message.toolName { fields["toolName"] = .string(toolName) }
        if let isError = message.isError { fields["isError"] = .bool(isError) }
        return .object(fields)
    }

    fileprivate static func decodeMessage(_ raw: JSONValue?, entryID: String) -> ConversationMessage? {
        guard let value = raw?.objectValue, let roleName = value["role"]?.stringValue,
              let role = MessageRole(rawValue: roleName == "hookMessage" ? "custom" : roleName) else { return nil }
        let timestamp = value["timestamp"].flatMap { raw -> Date? in
            switch raw {
            case .number(let milliseconds): return Date(timeIntervalSince1970: milliseconds / 1000)
            case .string(let iso): return JSONLSessionStore.parseDate(iso)
            default: return nil
            }
        } ?? .now
        let content = value["content"]
        let text: String
        let blocks: [JSONValue]
        if let direct = content?.stringValue { text = direct; blocks = [] }
        else if case .array(let values) = content { blocks = values; text = values.compactMap { block in
            guard block.objectValue?["type"]?.stringValue == "text" else { return nil }
            return block.objectValue?["text"]?.stringValue
        }.joined() }
        else { text = ""; blocks = [] }
        let calls = blocks.compactMap { block -> ToolCall? in
            guard let object = block.objectValue, object["type"]?.stringValue == "toolCall",
                  let id = object["id"]?.stringValue, let name = object["name"]?.stringValue else { return nil }
            return ToolCall(id: id, name: name, arguments: object["arguments"] ?? .object([:]))
        }
        return ConversationMessage(id: entryID, role: role, timestamp: timestamp, text: text, toolCalls: calls,
                                  toolCallID: value["toolCallId"]?.stringValue,
                                  toolName: value["toolName"]?.stringValue,
                                  isError: value["isError"]?.boolValue)
    }

    private static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

public enum SessionStoreError: Error, Sendable, LocalizedError {
    case invalidHeader
    case encoding
    case invalidID
    case entryNotFound(String)
    case invalidEntry(line: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: return "Invalid Pi session header"
        case .encoding: return "Could not encode session record"
        case .invalidID: return "Session ID contains unsupported characters"
        case .entryNotFound(let id): return "Session entry not found: \(id)"
        case .invalidEntry(let line, let reason): return "Invalid session record at line \(line): \(reason)"
        }
    }
}

public actor InMemorySessionStore: SessionStore {
    private var snapshots: [String: SessionSnapshot] = [:]
    public init() {}

    public func create(cwd: URL, metadata: SessionMetadata = SessionMetadata()) throws -> SessionSnapshot {
        let id = UUID().uuidString.lowercased()
        let now = JSONLSessionStore.isoHeader(timestamp: .now, id: id, cwd: cwd.path, metadata: metadata)
        let snapshot = SessionSnapshot(id: id, cwd: cwd.path, header: now)
        snapshots[id] = snapshot
        return snapshot
    }

    public func load(id: String) throws -> SessionSnapshot {
        guard let snapshot = snapshots[id] else { throw SessionStoreError.invalidID }
        return snapshot
    }

    public func load(fileURL: URL) throws -> SessionSnapshot { throw SessionStoreError.invalidID }

    public func append(_ message: ConversationMessage, to snapshot: SessionSnapshot) throws -> SessionSnapshot {
        var updated = snapshot
        updated.entries.append(SessionEntry(id: message.id, parentID: snapshot.activeLeafID,
                                            timestamp: message.timestamp, message: message))
        updated.activeLeafID = message.id
        snapshots[snapshot.id] = updated
        return updated
    }

    public func appendCompaction(summary: String, firstKeptEntryID: String, to snapshot: SessionSnapshot) throws -> SessionSnapshot {
        guard snapshot.entries.contains(where: { $0.id == firstKeptEntryID }) else {
            throw SessionStoreError.entryNotFound(firstKeptEntryID)
        }
        let id = UUID().uuidString.lowercased()
        let timestamp = Date()
        let record: [String: JSONValue] = [
            "type": .string("compaction"), "id": .string(id),
            "parentId": snapshot.activeLeafID.map(JSONValue.string) ?? .null,
            "timestamp": .string(JSONLSessionStore.formatDate(timestamp)), "summary": .string(summary),
            "firstKeptEntryId": .string(firstKeptEntryID)
        ]
        var updated = snapshot
        updated.entries.append(SessionEntry(id: id, parentID: snapshot.activeLeafID, timestamp: timestamp,
                                            rawValue: .object(record)))
        updated.activeLeafID = id
        snapshots[snapshot.id] = updated
        return updated
    }

    public func setActiveLeaf(_ entryID: String, in snapshot: SessionSnapshot) throws -> SessionSnapshot {
        guard entryID.isEmpty || snapshot.entries.contains(where: { $0.id == entryID }) else { throw SessionStoreError.entryNotFound(entryID) }
        var updated = snapshot; updated.activeLeafID = entryID.isEmpty ? nil : entryID
        snapshots[snapshot.id] = updated
        return updated
    }

    public func list(cwd: URL, limit: Int? = nil) -> [SessionSummary] {
        let values = snapshots.values.filter { $0.cwd == cwd.standardizedFileURL.path }.map {
            SessionSummary(id: $0.id, cwd: $0.cwd, updatedAt: $0.entries.last?.timestamp ?? .distantPast,
                           messageCount: $0.entries.filter { $0.message != nil }.count)
        }.sorted { $0.updatedAt > $1.updatedAt }
        return limit.map { Array(values.prefix(max(0, $0))) } ?? values
    }
}

private extension JSONLSessionStore {
    static func isoHeader(timestamp: Date, id: String, cwd: String, metadata: SessionMetadata) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("session"), "version": .number(3), "id": .string(id),
                                          "timestamp": .string(formatDate(timestamp)), "cwd": .string(cwd)]
        if let parent = metadata.parentSession { fields["parentSession"] = .string(parent) }
        return .object(fields)
    }
}
