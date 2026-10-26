import Foundation
import PiTypes
import PiAgentCore

public typealias AgentPluginCommand = AgentCommand

/// Implemented by a statically linked Swift package and explicitly registered by its host.
public protocol AgentPlugin: Sendable {
    var id: String { get }
    var version: String { get }
    var tools: [AgentTool] { get }
    var middleware: [any AgentMiddleware] { get }
    var commands: [AgentPluginCommand] { get }
}

public extension AgentPlugin {
    var middleware: [any AgentMiddleware] { [] }
    var commands: [AgentPluginCommand] { [] }
}

public struct RegisteredAgentPlugins: Sendable {
    public let tools: [AgentTool]
    public let middleware: [any AgentMiddleware]
    public let commands: [String: AgentPluginCommand]
    public let identifiers: [String]
}

public struct AgentPluginRegistry: Sendable {
    private var plugins: [String: any AgentPlugin] = [:]
    public init() {}

    public mutating func register(_ plugin: any AgentPlugin) throws {
        guard Self.isValidIdentifier(plugin.id) else { throw AgentPluginError.invalidIdentifier(plugin.id) }
        guard plugins[plugin.id] == nil else { throw AgentPluginError.duplicatePlugin(plugin.id) }
        plugins[plugin.id] = plugin
        do { _ = try resolve() }
        catch { plugins.removeValue(forKey: plugin.id); throw error }
    }

    public func resolve() throws -> RegisteredAgentPlugins {
        var names = Set<String>()
        var tools: [AgentTool] = []
        var middleware: [any AgentMiddleware] = []
        var commands: [String: AgentPluginCommand] = [:]
        for plugin in plugins.values.sorted(by: { $0.id < $1.id }) {
            for tool in plugin.tools {
                let name = "plugin_\(plugin.id)_\(tool.declaration.name)"
                guard names.insert(name).inserted else { throw AgentPluginError.duplicateTool(name) }
                var namespaced = tool
                namespaced.declaration.name = name
                tools.append(namespaced)
            }
            middleware.append(contentsOf: plugin.middleware)
            for command in plugin.commands {
                guard Self.isValidIdentifier(command.name) else { throw AgentPluginError.invalidCommandName(command.name) }
                let name = "\(plugin.id):\(command.name)"
                guard commands[name] == nil else { throw AgentPluginError.duplicateCommand(name) }
                commands[name] = command
            }
        }
        return RegisteredAgentPlugins(tools: tools, middleware: middleware, commands: commands,
                                      identifiers: plugins.keys.sorted())
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
}

public enum AgentPluginError: Error, LocalizedError {
    case invalidIdentifier(String)
    case invalidCommandName(String)
    case duplicatePlugin(String)
    case duplicateTool(String)
    case duplicateCommand(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id): "Invalid plugin identifier: \(id)"
        case .invalidCommandName(let name): "Invalid plugin command name: \(name)"
        case .duplicatePlugin(let id): "Plugin already registered: \(id)"
        case .duplicateTool(let name): "Plugin tool name collision: \(name)"
        case .duplicateCommand(let name): "Plugin command name collision: \(name)"
        }
    }
}
