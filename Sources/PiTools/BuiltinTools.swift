import Foundation
import PiTypes
import PiProviders
import PiAgentCore

public enum BuiltinTools {
    public static func read() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "read", description: "Read a UTF-8 text file", inputSchema: objectSchema(["path": stringSchema])), permission: .readOnly) { _, args, context in
            let url = try safeURL(args, context)
            let text = try String(contentsOf: url, encoding: .utf8)
            return ToolResult(text: text, details: .object(["path": .string(url.path)]))
        }
    }

    public static func write() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "write", description: "Write UTF-8 text to a file", inputSchema: objectSchema(["path": stringSchema, "content": stringSchema])), permission: .workspaceWrite) { _, args, context in
            let object = args.objectValue ?? [:]
            let url = try safeURL(args, context)
            guard let content = object["content"]?.stringValue else { throw ToolFailure.invalidArguments("content must be a string") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return ToolResult(text: "Wrote \(content.utf8.count) bytes to \(url.path)")
        }
    }

    public static func edit() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "edit", description: "Replace one exact string in a text file", inputSchema: objectSchema(["path": stringSchema, "oldText": stringSchema, "newText": stringSchema])), permission: .workspaceWrite) { _, args, context in
            let object = args.objectValue ?? [:]
            let url = try safeURL(args, context)
            guard let oldText = object["oldText"]?.stringValue, let newText = object["newText"]?.stringValue else {
                throw ToolFailure.invalidArguments("oldText and newText must be strings")
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            guard let range = source.range(of: oldText) else { throw ToolFailure.notFound("oldText not found") }
            guard source[range.upperBound...].range(of: oldText) == nil else { throw ToolFailure.invalidArguments("oldText occurs more than once") }
            let updated = source.replacingCharacters(in: range, with: newText)
            try Data(updated.utf8).write(to: url, options: .atomic)
            let diff = unifiedReplacementDiff(path: url.path, oldText: oldText, newText: newText)
            return ToolResult(text: diff, details: .object(["changed": .bool(true), "diff": .string(diff)]))
        }
    }

    public static func ls() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "ls", description: "List files and directories", inputSchema: objectSchema(["path": stringSchema])), permission: .readOnly) { _, args, context in
            let url = try safeURL(args, context)
            let items = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            return ToolResult(text: items.joined(separator: "\n"))
        }
    }

    public static func grep() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "grep", description: "Search text files for a literal string", inputSchema: objectSchema(["path": stringSchema, "query": stringSchema])), permission: .readOnly) { _, args, context in
            let object = args.objectValue ?? [:]
            let root = try safeURL(args, context)
            guard let query = object["query"]?.stringValue else { throw ToolFailure.invalidArguments("query must be a string") }
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            var matches: [String] = []
            while let file = files?.nextObject() as? URL {
                try context.cancellation.throwIfCancelled()
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.localizedCaseInsensitiveContains(query) {
                    matches.append("\(file.path):\(index + 1):\(line)")
                }
            }
            return ToolResult(text: matches.prefix(500).joined(separator: "\n"))
        }
    }

    public static func find() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "find", description: "Find files by name substring", inputSchema: objectSchema(["path": stringSchema, "query": stringSchema])), permission: .readOnly) { _, args, context in
            let object = args.objectValue ?? [:]
            let root = try safeURL(args, context)
            guard let query = object["query"]?.stringValue else { throw ToolFailure.invalidArguments("query must be a string") }
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            var results: [String] = []
            while let file = files?.nextObject() as? URL {
                try context.cancellation.throwIfCancelled()
                if file.lastPathComponent.localizedCaseInsensitiveContains(query) { results.append(file.path) }
            }
            return ToolResult(text: results.prefix(1000).joined(separator: "\n"))
        }
    }

    public static func bash() -> AgentTool {
        AgentTool(declaration: ToolDeclaration(name: "bash", description: "Run a shell command in the working directory", inputSchema: objectSchema(["command": stringSchema])), executionPolicy: .serialOnly, permission: .shell) { _, args, context in
            guard let command = args.objectValue?["command"]?.stringValue else { throw ToolFailure.invalidArguments("command must be a string") }
            try context.cancellation.throwIfCancelled()
            return try await Task.detached(priority: .userInitiated) {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-lc", command]; process.currentDirectoryURL = context.workingDirectory
                let stdout = Pipe(); let stderr = Pipe()
                process.standardOutput = stdout; process.standardError = stderr
                try process.run()
                let startedAt = Date()
                var timedOut = false
                let stdoutReader = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
                let stderrReader = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
                while process.isRunning {
                    if context.cancellation.isCancelled || Task.isCancelled { process.terminate() }
                    if Date().timeIntervalSince(startedAt) > context.processTimeout {
                        timedOut = true; process.terminate()
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let stdoutData = await stdoutReader.value
                let stderrData = await stderrReader.value
                if context.cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                let outputText = String(data: stdoutData, encoding: .utf8) ?? "<non-UTF8 stdout>"
                let errorText = String(data: stderrData, encoding: .utf8) ?? "<non-UTF8 stderr>"
                let status = process.terminationStatus
                return ToolResult(text: outputText, details: .object([
                    "stderr": .string(errorText), "exitCode": .number(Double(status)), "timedOut": .bool(timedOut)
                ]), isError: status != 0 || timedOut)
            }.value
        }
    }

    public static let all: [AgentTool] = [read(), write(), edit(), grep(), find(), ls(), bash()]

    private static func unifiedReplacementDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = "--- a/\(path)\n+++ b/\(path)"
        return header + "\n@@ -1,\(oldLines.count) +1,\(newLines.count) @@\n" +
            oldLines.map { "-\($0)" }.joined(separator: "\n") + "\n" +
            newLines.map { "+\($0)" }.joined(separator: "\n")
    }

    private static let stringSchema: JSONValue = .object(["type": .string("string")])
    private static func objectSchema(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private static func safeURL(_ args: JSONValue, _ context: ToolContext) throws -> URL {
        guard let path = args.objectValue?["path"]?.stringValue else { throw ToolFailure.invalidArguments("path must be a string") }
        let root = context.workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { throw ToolFailure.pathOutsideWorkspace }
        return candidate
    }
}

public enum ToolFailure: Error, LocalizedError {
    case invalidArguments(String), notFound(String), pathOutsideWorkspace
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .notFound(let message): return message
        case .pathOutsideWorkspace: return "Path resolves outside the working directory"
        }
    }
}
