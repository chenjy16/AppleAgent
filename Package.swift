// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleAgent",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PiTypes", targets: ["PiTypes"]),
        .library(name: "PiProviders", targets: ["PiProviders"]),
        .library(name: "PiAgentCore", targets: ["PiAgentCore"]),
        .library(name: "PiSession", targets: ["PiSession"]),
        .library(name: "PiTools", targets: ["PiTools"]),
        .library(name: "PiRuntime", targets: ["PiRuntime"]),
        .library(name: "PiRPC", targets: ["PiRPC"]),
        .executable(name: "apple-agent", targets: ["AppleAgentCLI"]),
        .executable(name: "apple-agent-app", targets: ["AppleAgentApp"]),
    ],
    targets: [
        .target(name: "PiTypes"),
        .target(name: "PiProviders", dependencies: ["PiTypes"]),
        .target(name: "PiSession", dependencies: ["PiTypes"]),
        .target(name: "PiAgentCore", dependencies: ["PiTypes", "PiProviders", "PiSession"]),
        .target(name: "PiTools", dependencies: ["PiTypes", "PiProviders", "PiAgentCore"]),
        .target(name: "PiRuntime", dependencies: ["PiTypes", "PiProviders", "PiSession", "PiAgentCore", "PiTools"]),
        .target(name: "PiRPC", dependencies: ["PiTypes", "PiRuntime"]),
        .testTarget(name: "PiSessionTests", dependencies: ["PiTypes", "PiSession"]),
        .testTarget(name: "PiAgentCoreTests", dependencies: ["PiTypes", "PiProviders", "PiSession", "PiAgentCore"]),
        .testTarget(name: "PiRPCTests", dependencies: ["PiTypes", "PiProviders", "PiRuntime", "PiAgentCore", "PiRPC"]),
        .testTarget(name: "PiProviderTests", dependencies: ["PiTypes", "PiProviders"]),
        .testTarget(name: "PiToolsTests", dependencies: ["PiTypes", "PiProviders", "PiAgentCore", "PiTools"]),
        .executableTarget(name: "AppleAgentCLI", dependencies: ["PiTypes", "PiProviders", "PiSession", "PiAgentCore", "PiTools", "PiRuntime", "PiRPC"]),
        .executableTarget(name: "AppleAgentApp", dependencies: ["PiTypes", "PiProviders", "PiAgentCore", "PiRuntime"]),
    ]
)
