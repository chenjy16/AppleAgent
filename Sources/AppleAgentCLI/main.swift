import Foundation
import PiTypes
import PiProviders
import PiSession
import PiAgentCore
import PiTools
import PiRuntime
import PiRPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct AppleAgentCLI {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("apple-agent: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let parsed = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
        if parsed.flags.contains("help") { printHelp(); return }
        let cwd = URL(fileURLWithPath: parsed.values["cwd"] ?? FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
        let permissionGrantStore = FilePermissionGrantStore()
        if parsed.flags.contains("revoke-project-permissions") {
            try await permissionGrantStore.revokeProjectGrants(for: cwd.path)
            print("Revoked project permission grants for \(cwd.path)")
            return
        }
        let userConfig = try loadConfig(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/apple-agent/config.json"))
        let projectConfig = try loadConfig(cwd.appendingPathComponent(".apple-agent.json"))
        let environment = ProcessInfo.processInfo.environment
        let providerID = value("provider", parsed, environment, projectConfig, userConfig)
            ?? (environment["GEMINI_API_KEY"] != nil || environment["GOOGLE_API_KEY"] != nil
                ? "gemini" : (environment["ANTHROPIC_API_KEY"] == nil ? "openai" : "anthropic"))
        let modelID = value("model", parsed, environment, projectConfig, userConfig) ?? (providerID == "anthropic" ? "claude-sonnet-4-5" : (providerID == "gemini" ? "gemini-3.8-flash" : "gpt-4o-mini"))
        let baseURL = value("base-url", parsed, environment, projectConfig, userConfig)
        let mode = value("mode", parsed, environment, projectConfig, userConfig) ?? "print"
        guard ["print", "json", "rpc", "tui"].contains(mode) else { throw CLIError.unsupportedMode(mode) }
        let sessionDirectory = value("session-dir", parsed, environment, projectConfig, userConfig).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let sessionID = parsed.values["session"] ?? parsed.values["session-id"]
        let sessionEnabled = !parsed.flags.contains("no-session")
        let prompt = parsed.values["prompt"] ?? parsed.positionals.joined(separator: " ")
        let permissionValue = value("permissions", parsed, environment, projectConfig, userConfig) ?? "allow"
        let permissionPolicy: ToolPermissionPolicy
        switch permissionValue {
        case "allow": permissionPolicy = .allowAll
        case "read-only": permissionPolicy = .readOnly
        case "deny": permissionPolicy = .denyAll
        case "ask": permissionPolicy = .ask
        default: throw CLIError.invalidPermissions(permissionValue)
        }
        if parsed.flags.contains("list-models") {
            let provider = try makeProvider(providerID, baseURL: baseURL, environment: environment)
            guard let source = provider as? any ModelCatalogSource else { throw CLIError.catalogUnavailable(providerID) }
            let result = try await ModelCatalog().models(from: source)
            for model in result.models { print("\(model.id)\(model.contextWindow.map { " · \($0) context" } ?? "")") }
            if result.isStale { FileHandle.standardError.write(Data("Showing cached model list from \(result.fetchedAt).\n".utf8)) }
            return
        }
        
        let mcpConfigURL = value("mcp-config", parsed, environment, projectConfig, userConfig).map { URL(fileURLWithPath: $0) }
        let restrictRefreshTools = parsed.values["tools"] != nil
        let allowedTools = restrictRefreshTools ? Set(parsed.values["tools"]!.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) : nil
        if restrictRefreshTools && allowedTools?.contains("none") == true || allowedTools?.isEmpty == true {
            // Handled inside RuntimeFactory (if allowedTools is empty, it returns 0 tools)
        }

        let terminalApproval = TerminalApprovalBroker()
        let localPermissionHandler: ToolPermissionHandler
        if mode == "tui" {
            localPermissionHandler = { request, cancellation in
                await terminalApproval.request(request, cancellation: cancellation)
            }
        } else {
            localPermissionHandler = permissionApprovalHandler(interactive: mode == "print" && isatty(STDIN_FILENO) == 1)
        }
        let makeAgent: RPCHost.AgentFactory = { session, selectedProvider, selectedModel, parentSession, rpcPermissionHandler in
            let activeProviderID = selectedProvider ?? providerID
            let activeModelID = selectedModel ?? modelID
            let provider = try makeProvider(activeProviderID, baseURL: baseURL, environment: environment)
            let model = ModelDescriptor(id: activeModelID, providerID: activeProviderID)
            let agent = try await RuntimeFactory.makeAgent(provider: provider, model: model, cwd: cwd,
                                                       sessionDirectory: sessionDirectory,
                                                       sessionID: session,
                                                       sessionEnabled: sessionEnabled, parentSession: parentSession,
                                                       permissionPolicy: permissionPolicy,
                                                       permissionHandler: mode == "rpc" ? rpcPermissionHandler : localPermissionHandler,
                                                       permissionGrantStore: permissionGrantStore,
                                                       commands: registeredMCPCommands, tools: enabledTools)
            await refreshManager.attach(agent)
            return agent
        }
        if mode == "rpc" {
            let host = RPCHost(sessionID: sessionID, providerID: providerID, modelID: modelID, makeAgent: makeAgent)
            await host.run()
            return
        }
        if mode == "tui" {
            let agent = try await makeAgent(sessionID, providerID, modelID, nil, localPermissionHandler)
            await TerminalUI.run(agent: agent, approval: terminalApproval,
                                 firstPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt)
            return
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError.promptRequired }
        let agent = try await makeAgent(sessionID, providerID, modelID, nil, localPermissionHandler)
        if mode == "json" {
            FileHandle.standardOutput.write(await agent.currentSessionHeader().encodedData)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        var runFailure: String?
        for await event in await agent.events(for: prompt) {
            switch event {
            case .textDelta(_, let delta):
                if mode == "print" { FileHandle.standardOutput.write(Data(delta.utf8)) }
            case .failed(let code, let message):
                FileHandle.standardError.write(Data("\(code): \(message)\n".utf8))
                runFailure = "\(code): \(message)"
            default:
                if mode == "json" {
                    let value = jsonEvent(event)
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([0x0A]))
                }
            }
        }
        if mode == "print" { FileHandle.standardOutput.write(Data([0x0A])) }
        if let runFailure { throw CLIError.agentFailure(runFailure) }
    }

    private static func renderInteractiveTurn(_ agent: Agent, prompt: String) async {
        FileHandle.standardOutput.write(Data("\nassistant: ".utf8))
        for await event in await agent.events(for: prompt) {
            switch event {
            case .textDelta(_, let delta): FileHandle.standardOutput.write(Data(delta.utf8))
            case .toolStart(let call): FileHandle.standardError.write(Data("\n[tool: \(call.name)]\n".utf8))
            case .toolEnd(_, let result):
                if result.isError { FileHandle.standardError.write(Data("[tool error] \(result.text)\n".utf8)) }
            case .permissionRequest: break
            case .failed(_, let message): FileHandle.standardError.write(Data("\n[error] \(message)\n".utf8))
            default: break
            }
        }
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func permissionApprovalHandler(interactive: Bool) -> ToolPermissionHandler {
        { request, cancellation in
            if cancellation.isCancelled { return .deny }
            guard interactive else { return .deny }
            let argumentText = String(data: request.arguments.encodedData, encoding: .utf8) ?? "{}"
            FileHandle.standardError.write(Data("\nAllow \(request.permission.rawValue) tool '\(request.toolName)' with arguments \(argumentText)? [y once / s session / p project / N deny] ".utf8))
            guard let answer = readLine() else { return .deny }
            switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "y", "yes": return .allowOnce
            case "s", "session": return .allowForSession
            case "p", "project": return .allowForProject
            default: return .deny
            }
        }
    }

    private static func value(_ key: String, _ cli: CLIArguments, _ env: [String: String],
                              _ project: [String: String], _ user: [String: String]) -> String? {
        let envName = "APPLE_AGENT_" + key.replacingOccurrences(of: "-", with: "_").uppercased()
        return cli.values[key] ?? env[envName] ?? project[key] ?? user[key]
    }

    private static func loadConfig(_ url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        do { return try JSONDecoder().decode([String: String].self, from: data) }
        catch { throw CLIError.invalidConfig(url.path, error.localizedDescription) }
    }

    private static func makeProvider(_ id: String, baseURL: String?, environment: [String: String]) throws -> any ModelProvider {
        let store = CompositeCredentialStore([EnvironmentCredentialStore(values: environment), KeychainCredentialStore()])
        guard let key = store.apiKey(for: id) else {
            let credential = id == "anthropic" ? "ANTHROPIC_API_KEY" : (id == "gemini" ? "GEMINI_API_KEY or GOOGLE_API_KEY" : "OPENAI_API_KEY")
            throw CLIError.missingCredential("\(credential) or Keychain item (apple-agent/\(id))")
        }
        if id == "anthropic" { return AnthropicProvider(apiKey: key) }
        if id == "gemini" {
            let endpoint = baseURL ?? "https://generativelanguage.googleapis.com/v1beta"
            guard let url = URL(string: endpoint), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
                throw CLIError.invalidURL(endpoint)
            }
            return GoogleGeminiProvider(apiKey: key, baseURL: url)
        }
        let endpoint = baseURL ?? environment["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1"
        guard let url = URL(string: endpoint), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw CLIError.invalidURL(endpoint)
        }
        return OpenAICompatibleProvider(id: id, baseURL: url, apiKey: key)
    }

    private static func makeMCPCommands(
        serverName: String,
        promptList: (@Sendable () async throws -> JSONValue)?,
        promptGet: (@Sendable (String, [String: JSONValue]) async throws -> JSONValue)?,
        resourceList: (@Sendable () async throws -> JSONValue)?,
        resourceRead: (@Sendable (String) async throws -> JSONValue)?
    ) -> [AgentCommand] {
        let safeName = String(serverName.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        var commands: [AgentCommand] = []
        if let promptList, let promptGet {
            commands.append(AgentCommand(name: "mcp_\(safeName):prompts", description: "List prompts from MCP server \(serverName)") { _, _ in
                let value = try await promptList()
                let names = value.objectValue?["prompts"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
                return names.isEmpty ? "This MCP server has no prompts." : names.joined(separator: "\n")
            })
            commands.append(AgentCommand(name: "mcp_\(safeName):prompt", description: "Select an MCP prompt and send it to the Agent", sendsResultToAgent: true) { arguments, _ in
                guard let name = arguments.first, !name.isEmpty else { throw CLIError.commandUsage("/mcp_\(safeName):prompt <name> [key=value ...]") }
                var values: [String: JSONValue] = [:]
                for argument in arguments.dropFirst() {
                    guard let split = argument.firstIndex(of: "=") else { throw CLIError.commandUsage("Prompt arguments use key=value") }
                    let key = String(argument[..<split])
                    let raw = String(argument[argument.index(after: split)...])
                    guard !key.isEmpty else { throw CLIError.commandUsage("Prompt argument names cannot be empty") }
                    values[key] = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .string(raw)
                }
                let prompt = try await promptGet(name, values)
                let text = Self.mcpPromptText(prompt)
                guard !text.isEmpty else { throw CLIError.commandUsage("MCP prompt returned no text content") }
                return "Use the following selected MCP prompt as the user's task:\n\n\(text)"
            })
        }
        if let resourceList, let resourceRead {
            commands.append(AgentCommand(name: "mcp_\(safeName):resources", description: "List resources from MCP server \(serverName)") { _, _ in
                let value = try await resourceList()
                let resources = value.objectValue?["resources"]?.arrayValue ?? []
                let lines = resources.compactMap { resource -> String? in
                    guard let fields = resource.objectValue, let uri = fields["uri"]?.stringValue else { return nil }
                    return "\(uri)\(fields["name"]?.stringValue.map { " · \($0)" } ?? "")"
                }
                return lines.isEmpty ? "This MCP server has no resources." : lines.joined(separator: "\n")
            })
            commands.append(AgentCommand(name: "mcp_\(safeName):resource", description: "Read a selected MCP resource and send it to the Agent", sendsResultToAgent: true) { arguments, _ in
                guard !arguments.isEmpty else { throw CLIError.commandUsage("/mcp_\(safeName):resource <uri>") }
                let value = try await resourceRead(arguments.joined(separator: " "))
                let text = Self.mcpResourceText(value)
                guard !text.isEmpty else { throw CLIError.commandUsage("MCP resource returned no text content") }
                return "Use the following selected MCP resource as context for the user's task:\n\n\(text)"
            })
        }
        return commands
    }

    private static func mcpPromptText(_ value: JSONValue) -> String {
        let messages = value.objectValue?["messages"]?.arrayValue ?? []
        return messages.compactMap { item -> String? in
            guard let fields = item.objectValue else { return nil }
            let role = fields["role"]?.stringValue ?? "user"
            let content = fields["content"]
            let text: String
            if let direct = content?.stringValue { text = direct }
            else if let blocks = content?.arrayValue {
                text = blocks.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
            } else { text = content?.objectValue?["text"]?.stringValue ?? "" }
            return text.isEmpty ? nil : "\(role): \(text)"
        }.joined(separator: "\n\n")
    }

    private static func mcpResourceText(_ value: JSONValue) -> String {
        let contents = value.objectValue?["contents"]?.arrayValue ?? []
        let text = contents.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
        return text.isEmpty ? String(data: value.encodedData, encoding: .utf8) ?? "" : text
    }

    private static func selectTools(_ requested: String?, from availableTools: [AgentTool]) throws -> [AgentTool] {
        guard let requested else { return availableTools }
        if requested == "none" || requested.isEmpty { return [] }
        let available = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.declaration.name, $0) })
        let names = requested.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let unknown = names.filter { available[$0] == nil }
        guard unknown.isEmpty else { throw CLIError.unknownTools(unknown) }
        return names.compactMap { available[$0] }
    }

    private static func jsonEvent(_ event: AgentEvent) -> [String: Any] {
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
        case .permissionRequest(let request): return ["type": "permission_request", "request": ["id": request.id, "toolName": request.toolName, "permission": request.permission.rawValue, "arguments": jsonObject(request.arguments)]]
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
        var result: [String: Any] = ["role": message.role.rawValue, "content": content,
                                     "timestamp": Int(message.timestamp.timeIntervalSince1970 * 1000)]
        if let id = message.toolCallID { result["toolCallId"] = id }
        if let name = message.toolName { result["toolName"] = name }
        if let isError = message.isError { result["isError"] = isError }
        return result
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

    private static func printHelp() {
        print("""
        apple-agent [options] [prompt]

        Options:
          --mode print|json|rpc|tui   Output mode (default: print)
          --list-models              Fetch and print the selected provider's model catalog
          --provider ID              openai, anthropic, gemini, or compatible provider ID
          --model ID                 Model identifier
          --base-url URL             OpenAI-compatible API base URL
          --cwd PATH                 Working directory
          --session ID               Resume a stored session
          --session-dir PATH         Session storage directory
          --no-session               Keep this run in memory only
          --tools LIST|none          Comma-separated built-in or MCP tool names
          --mcp-config PATH          JSON file with MCP stdio/Streamable HTTP servers
          --permissions allow|read-only|deny|ask
                                     Permission ceiling for tool execution
          --revoke-project-permissions
                                     Remove remembered grants for the current project
          --prompt TEXT              Prompt text (otherwise positional arguments)

        Config precedence: command line > APPLE_AGENT_* environment > .apple-agent.json > ~/.config/apple-agent/config.json.
        API credentials are read from OPENAI_API_KEY, ANTHROPIC_API_KEY, or GEMINI_API_KEY.
        """)
    }
}

private struct CLIArguments {
    var values: [String: String] = [:]
    var flags = Set<String>()
    var positionals: [String] = []
    private static let valueOptions: Set<String> = ["mode", "provider", "model", "base-url", "cwd", "session", "session-id", "session-dir", "tools", "mcp-config", "permissions", "prompt"]
    private static let flagOptions: Set<String> = ["help", "no-session", "list-models", "revoke-project-permissions"]

    static func parse(_ args: [String]) throws -> CLIArguments {
        var parsed = CLIArguments(); var index = 0; var consumePositionals = false
        while index < args.count {
            let argument = args[index]
            if consumePositionals { parsed.positionals.append(argument); index += 1; continue }
            if argument == "--" { consumePositionals = true; index += 1; continue }
            if argument.hasPrefix("--") {
                let split = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(split[0])
                if flagOptions.contains(key) { parsed.flags.insert(key); index += 1; continue }
                guard valueOptions.contains(key) else { throw CLIError.unknownOption(key) }
                let value: String
                if split.count == 2 { value = String(split[1]); index += 1 }
                else {
                    guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw CLIError.missingOptionValue(key) }
                    value = args[index + 1]; index += 2
                }
                parsed.values[key] = value
            } else { parsed.positionals.append(argument); index += 1 }
        }
        return parsed
    }
}

private enum CLIError: Error, LocalizedError {
    case promptRequired, missingCredential(String), invalidURL(String), invalidConfig(String, String), agentFailure(String)
    case unsupportedMode(String), unknownOption(String), missingOptionValue(String), unknownTools([String]), invalidMCPConfig(String, String), mcpRequiresAllow
    case invalidPermissions(String), catalogUnavailable(String)
    case commandUsage(String)
    var errorDescription: String? {
        switch self {
        case .promptRequired: return "Provide a prompt or use --mode rpc"
        case .missingCredential(let name): return "Missing environment variable \(name)"
        case .invalidURL(let value): return "Invalid HTTP base URL: \(value)"
        case .invalidConfig(let path, let reason): return "Could not read config at \(path): \(reason)"
        case .agentFailure(let reason): return reason
        case .unsupportedMode(let mode): return "Unsupported mode: \(mode)"
        case .unknownOption(let option): return "Unknown option: --\(option)"
        case .missingOptionValue(let option): return "Missing value for --\(option)"
        case .unknownTools(let names): return "Unknown tools: \(names.joined(separator: ", "))"
        case .invalidMCPConfig(let path, let reason): return "Could not read MCP config at \(path): \(reason)"
        case .mcpRequiresAllow: return "MCP servers run as child processes with the current user's privileges; use --permissions allow or ask to enable them"
        case .invalidPermissions(let value): return "Invalid --permissions value '\(value)' (expected allow, read-only, deny, or ask)"
        case .catalogUnavailable(let provider): return "Provider '\(provider)' does not expose a model catalog"
        case .commandUsage(let usage): return "Usage: \(usage)"
        }
    }
}
