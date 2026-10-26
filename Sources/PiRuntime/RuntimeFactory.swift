import Foundation
import PiTypes
import PiProviders
import PiAgentCore
import PiSession
import PiTools

public enum RuntimeFactory {
    public static func makeAgent(provider: any ModelProvider, model: ModelDescriptor, cwd: URL,
                                 sessionDirectory: URL? = nil, sessionID: String? = nil,
                                 sessionEnabled: Bool = true, parentSession: String? = nil,
                                 permissionPolicy: ToolPermissionPolicy = .allowAll,
                                 middleware: [any AgentMiddleware] = [],
                                 permissionHandler: @escaping ToolPermissionHandler = { _, _ in .deny },
                                 permissionGrantStore: (any ToolPermissionGrantStore)? = nil,
                                 plugins: [any AgentPlugin] = [],
                                 commands: [AgentCommand] = [],
                                 tools: [AgentTool] = BuiltinTools.all,
                                 mcpConfig: URL? = nil,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 allowedTools: Set<String>? = nil) async throws -> Agent {
        let directory = sessionDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".apple-agent/sessions", isDirectory: true)
        let store: any SessionStore = sessionEnabled ? JSONLSessionStore(directory: directory) : InMemorySessionStore()
        let snapshot: SessionSnapshot
        if let sessionID {
            let candidate = URL(fileURLWithPath: sessionID)
            if candidate.pathExtension == "jsonl" { snapshot = try await store.load(fileURL: candidate) }
            else { snapshot = try await store.load(id: sessionID) }
        } else {
            snapshot = try await store.create(cwd: cwd, metadata: SessionMetadata(parentSession: parentSession))
        }
        let sessionWorkingDirectory = URL(fileURLWithPath: snapshot.cwd, isDirectory: true).standardizedFileURL
        let options = RuntimeOptions(model: model, workingDirectory: sessionWorkingDirectory)
        
        var registry = AgentPluginRegistry()
        for plugin in plugins { try registry.register(plugin) }
        let registered = try registry.resolve()
        
        var finalTools = tools + registered.tools
        var finalCommands = commands + Array(registered.commands.values)
        
        let refreshManager = MCPToolRefreshManager()
        if let mcpConfig {
            if permissionPolicy != .allowAll && permissionPolicy != .ask {
                throw RuntimeError.mcpRequiresAllow
            }
            let (mcpTools, mcpCommands, mcpRefreshSources) = try await loadMCP(
                configURL: mcpConfig,
                environment: environment,
                cwd: cwd
            )
            finalTools += mcpTools
            finalCommands += mcpCommands
            
            for source in mcpRefreshSources {
                Task {
                    let stream = await source.notifications()
                    for await notification in stream where notification.method == "notifications/tools/list_changed" {
                        do {
                            let loaded = try await source.loadTools()
                            let filtered = allowedTools.map { allowed in loaded.filter { allowed.contains($0.declaration.name) } } ?? loaded
                            await refreshManager.refresh(prefix: source.toolNamePrefix, tools: filtered)
                        } catch {
                            // Silent refresh failure
                        }
                    }
                }
            }
        }
        
        if let allowedTools {
            finalTools = finalTools.filter { allowedTools.contains($0.declaration.name) }
        }
        
        let allCommands = Dictionary(finalCommands.map { ($0.name, $0) },
                                     uniquingKeysWith: { first, _ in first })
        
        let agent = Agent(provider: provider, store: store, session: snapshot, options: options,
                     tools: finalTools, permissionPolicy: permissionPolicy,
                     middleware: middleware + registered.middleware, permissionHandler: permissionHandler,
                     permissionGrantStore: permissionGrantStore, commands: allCommands)
        await refreshManager.attach(agent)
        return agent
    }
    
    private static func loadMCP(configURL: URL, environment: [String: String], cwd: URL) async throws -> ([AgentTool], [AgentCommand], [MCPToolRefreshSource]) {
        let data = try Data(contentsOf: configURL)
        let configuration: MCPServerConfigFile
        do { configuration = try JSONDecoder().decode(MCPServerConfigFile.self, from: data) }
        catch { throw RuntimeError.invalidMCPConfig(configURL.path, error.localizedDescription) }
        
        var tools: [AgentTool] = []
        var commands: [AgentCommand] = []
        var refreshSources: [MCPToolRefreshSource] = []
        
        for name in configuration.servers.keys.sorted() {
            guard let serverConfig = configuration.servers[name] else { continue }
            switch serverConfig.transport {
            case "stdio":
                var resolvedConfig = serverConfig
                resolvedConfig.env = try CredentialReferenceResolver.resolve(serverConfig.env, environment: environment)
                let server = try MCPStdioClient.connect(name: name, configuration: resolvedConfig, workingDirectory: cwd)
                tools.append(contentsOf: try server.agentTools())
                let prefix = "mcp_\(String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }))_"
                refreshSources.append(MCPToolRefreshSource(toolNamePrefix: prefix,
                    notifications: { server.notifications() },
                    loadTools: { try server.agentTools() }))
                let promptList: (@Sendable () async throws -> JSONValue)? = server.supportsPrompts ? { @Sendable in try server.listPrompts() } : nil
                let promptGet: (@Sendable (String, [String: JSONValue]) async throws -> JSONValue)? = server.supportsPrompts ? { @Sendable prompt, args in
                    try server.getPrompt(name: prompt, arguments: args)
                } : nil
                let resourceList: (@Sendable () async throws -> JSONValue)? = server.supportsResources ? { @Sendable in try server.listResources() } : nil
                let resourceRead: (@Sendable (String) async throws -> JSONValue)? = server.supportsResources ? { @Sendable uri in try server.readResource(uri: uri) } : nil
                commands += makeMCPCommands(serverName: name, promptList: promptList, promptGet: promptGet,
                                               resourceList: resourceList, resourceRead: resourceRead)
            case "streamable-http":
                guard let rawURL = serverConfig.url, let endpoint = URL(string: rawURL) else {
                    throw RuntimeError.invalidMCPConfig(configURL.path, "server '\(name)' needs a valid url")
                }
                let resolvedHeaders = try CredentialReferenceResolver.resolve(serverConfig.headers, environment: environment)
                let server = try await MCPStreamableHTTPClient.connect(name: name, endpoint: endpoint, headers: resolvedHeaders)
                tools.append(contentsOf: try await server.agentTools())
                let prefix = "mcp_\(String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }))_"
                refreshSources.append(MCPToolRefreshSource(toolNamePrefix: prefix,
                    notifications: { await server.notifications() },
                    loadTools: { try await server.agentTools() }))
                let supportsPrompts = await server.supportsPrompts()
                let supportsResources = await server.supportsResources()
                let promptList: (@Sendable () async throws -> JSONValue)? = supportsPrompts ? { @Sendable in try await server.listPrompts() } : nil
                let promptGet: (@Sendable (String, [String: JSONValue]) async throws -> JSONValue)? = supportsPrompts ? { @Sendable prompt, args in
                    try await server.getPrompt(name: prompt, arguments: args)
                } : nil
                let resourceList: (@Sendable () async throws -> JSONValue)? = supportsResources ? { @Sendable in try await server.listResources() } : nil
                let resourceRead: (@Sendable (String) async throws -> JSONValue)? = supportsResources ? { @Sendable uri in try await server.readResource(uri: uri) } : nil
                commands += makeMCPCommands(serverName: name, promptList: promptList, promptGet: promptGet,
                                               resourceList: resourceList, resourceRead: resourceRead)
            default:
                throw RuntimeError.invalidMCPConfig(configURL.path, "unsupported transport '\(serverConfig.transport)' for server '\(name)'")
            }
        }
        return (tools, commands, refreshSources)
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
                guard let name = arguments.first, !name.isEmpty else { throw RuntimeError.commandUsage("/mcp_\(safeName):prompt <name> [key=value ...]") }
                var values: [String: JSONValue] = [:]
                for argument in arguments.dropFirst() {
                    guard let split = argument.firstIndex(of: "=") else { throw RuntimeError.commandUsage("Prompt arguments use key=value") }
                    let key = String(argument[..<split])
                    let raw = String(argument[argument.index(after: split)...])
                    guard !key.isEmpty else { throw RuntimeError.commandUsage("Prompt argument names cannot be empty") }
                    values[key] = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .string(raw)
                }
                let prompt = try await promptGet(name, values)
                let text = mcpPromptText(prompt)
                guard !text.isEmpty else { throw RuntimeError.commandUsage("MCP prompt returned no text content") }
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
                guard !arguments.isEmpty else { throw RuntimeError.commandUsage("/mcp_\(safeName):resource <uri>") }
                let value = try await resourceRead(arguments.joined(separator: " "))
                let text = mcpResourceText(value)
                guard !text.isEmpty else { throw RuntimeError.commandUsage("MCP resource returned no text content") }
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
}

public enum RuntimeError: Error, LocalizedError {
    case mcpRequiresAllow
    case invalidMCPConfig(String, String)
    case commandUsage(String)
    
    public var errorDescription: String? {
        switch self {
        case .mcpRequiresAllow: return "MCP servers run as child processes with the current user's privileges; use an allow or ask policy to enable them"
        case .invalidMCPConfig(let path, let reason): return "Could not read MCP config at \(path): \(reason)"
        case .commandUsage(let usage): return "Usage: \(usage)"
        }
    }
}

private struct MCPToolRefreshSource: Sendable {
    var toolNamePrefix: String
    var notifications: @Sendable () async -> AsyncStream<MCPNotification>
    var loadTools: @Sendable () async throws -> [AgentTool]
}

private actor MCPToolRefreshManager {
    private weak var agent: Agent?
    func attach(_ agent: Agent) { self.agent = agent }
    func refresh(prefix: String, tools: [AgentTool]) async {
        await agent?.replaceTools(withPrefix: prefix, using: tools)
    }
}
