import XCTest
import PiTypes
import PiProviders
import PiAgentCore
import PiRuntime

private struct FixturePlugin: AgentPlugin {
    let id: String
    let version = "1.0"
    let tools: [AgentTool]
    let commands: [AgentPluginCommand]
    var middleware: [any AgentMiddleware] { [] }

    init(id: String = "fixture", tools: [AgentTool]? = nil, commands: [AgentPluginCommand] = []) {
        self.id = id
        self.tools = tools ?? [AgentTool(declaration: ToolDeclaration(name: "inspect", description: "", inputSchema: .object(["type": .string("object")]))) { _, _, _ in
            ToolResult(text: "ok")
        }]
        self.commands = commands
    }
}

final class AgentPluginRegistryTests: XCTestCase {
    func testExplicitlyRegisteredPluginToolsAreNamespaced() throws {
        var registry = AgentPluginRegistry()
        try registry.register(FixturePlugin())
        let loaded = try registry.resolve()
        XCTAssertEqual(loaded.identifiers, ["fixture"])
        XCTAssertEqual(loaded.tools.map(\.declaration.name), ["plugin_fixture_inspect"])
    }

    func testDuplicatePluginRegistrationIsRejected() throws {
        var registry = AgentPluginRegistry()
        try registry.register(FixturePlugin())
        XCTAssertThrowsError(try registry.register(FixturePlugin()))
        XCTAssertEqual(try registry.resolve().identifiers, ["fixture"])
    }
    func testRejectsUnsafePluginCommandNames() throws {
        let plugin = FixturePlugin(id: "fixture", tools: [], commands: [
            AgentPluginCommand(name: "bad command", description: "Invalid") { _, _ in "no" }
        ])
        var registry = AgentPluginRegistry()
        XCTAssertThrowsError(try registry.register(plugin))
    }

}
