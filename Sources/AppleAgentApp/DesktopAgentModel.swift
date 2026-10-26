import Foundation
import AppKit
import Combine
import PiTypes
import PiProviders
import PiAgentCore
import PiRuntime

@MainActor
final class DesktopAgentModel: ObservableObject {
    @Published var providerID = UserDefaults.standard.string(forKey: "providerID") ?? "openai" { didSet { savePreferences(); invalidateAgentIfIdle() } }
    @Published var modelID = UserDefaults.standard.string(forKey: "modelID") ?? "gpt-4o-mini" { didSet { savePreferences(); invalidateAgentIfIdle() } }
    @Published var baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "" { didSet { savePreferences(); invalidateAgentIfIdle() } }
    @Published var permissionMode = UserDefaults.standard.string(forKey: "permissionMode") ?? "ask" { didSet { savePreferences(); invalidateAgentIfIdle() } }
    @Published var workingDirectoryPath = UserDefaults.standard.string(forKey: "workingDirectory") ?? FileManager.default.homeDirectoryForCurrentUser.path {
        didSet { savePreferences(); invalidateAgentIfIdle() }
    }
    @Published var messages: [ConversationMessage] = []
    @Published var streamingText = ""
    @Published var activity = ""
    @Published var errorMessage: String?
    @Published var pendingApproval: ToolPermissionRequest?
    @Published var availableModels: [ModelDescriptor] = []
    @Published var isRunning = false
    @Published var isLoadingModels = false
    @Published var sessionID: String? { didSet { savePreferences() } }

    init() {
        if UserDefaults.standard.string(forKey: "lastSessionID") != nil {
            Task { await restoreLastSessionIfAvailable() }
        }
    }

    private var agent: Agent?
    private var runTask: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<ToolPermissionDecision, Never>?
    private let credentials = CompositeCredentialStore()
    private let catalog = ModelCatalog()

    var providerOptions: [(id: String, title: String)] {
        [("openai", "OpenAI / Compatible"), ("anthropic", "Anthropic"), ("gemini", "Google Gemini")]
    }

    var hasCredential: Bool { credentials.apiKey(for: providerID) != nil }
    var selectedPermissionPolicy: ToolPermissionPolicy {
        switch permissionMode {
        case "read-only": .readOnly
        case "allow": .allowAll
        case "deny": .denyAll
        default: .ask
        }
    }

    func loadModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        Task {
            defer { isLoadingModels = false }
            do {
                let provider = try makeProvider()
                guard let source = provider as? any ModelCatalogSource else { return }
                let result = try await catalog.models(from: source, forceRefresh: true)
                availableModels = result.models
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Working Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectoryPath = url.standardizedFileURL.path
            startNewSession()
        }
    }

    func startNewSession() {
        guard !isRunning else { return }
        messages = []
        streamingText = ""
        activity = ""
        sessionID = nil
        UserDefaults.standard.removeObject(forKey: "lastSessionID")
        agent = nil
    }

    func send(_ prompt: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty, !isRunning else { return }
        runTask = Task { await run(prompt: cleanPrompt) }
    }

    func stop() {
        runTask?.cancel()
        Task { await agent?.abort() }
    }

    func resolvePermission(_ decision: ToolPermissionDecision) {
        pendingApproval = nil
        permissionContinuation?.resume(returning: decision)
        permissionContinuation = nil
    }

    private func run(prompt: String) async {
        isRunning = true
        streamingText = ""
        activity = "Preparing agent…"
        defer {
            isRunning = false
            runTask = nil
            if pendingApproval != nil { resolvePermission(.deny) }
        }
        do {
            let currentAgent: Agent
            if let agent {
                currentAgent = agent
            } else {
                currentAgent = try await makeAgent()
                agent = currentAgent
            }
            activity = "Thinking…"
            for await event in await currentAgent.events(for: prompt) {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(_, let delta): streamingText += delta
                case .toolStart(let call): activity = "Running \(call.name)…"
                case .toolEnd(_, let result): activity = result.isError ? "Tool returned an error" : "Tool finished"
                case .permissionRequest(let request): pendingApproval = request
                case .failed(let code, let message): errorMessage = "\(code): \(message)"
                case .agentEnd: activity = "Finishing…"
                case .agentSettled(let aborted):
                    activity = aborted ? "Stopped" : "Ready"
                    messages = await currentAgent.currentMessages()
                default: break
                }
            }
            messages = await currentAgent.currentMessages()
            sessionID = await currentAgent.currentSessionID()
        } catch {
            errorMessage = error.localizedDescription
            activity = "Failed"
        }
    }

    private func restoreLastSessionIfAvailable() async {
        guard hasCredential, agent == nil else { return }
        do {
            let restored = try await makeAgent()
            agent = restored
            messages = await restored.currentMessages()
            sessionID = await restored.currentSessionID()
            activity = "Ready"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func invalidateAgentIfIdle() {
        guard !isRunning else { return }
        agent = nil
    }

    private func makeAgent() async throws -> Agent {
        let provider = try makeProvider()
        let model = ModelDescriptor(id: modelID.trimmingCharacters(in: .whitespaces), providerID: providerID)
        let createdAgent = try await RuntimeFactory.makeAgent(
            provider: provider,
            model: model,
            cwd: URL(fileURLWithPath: workingDirectoryPath, isDirectory: true),
            sessionID: UserDefaults.standard.string(forKey: "lastSessionID"),
            permissionPolicy: selectedPermissionPolicy,
            permissionHandler: { [weak self] request, _ in
                await self?.requestPermission(for: request) ?? .deny
            },
            permissionGrantStore: FilePermissionGrantStore()
        )
        sessionID = await createdAgent.currentSessionID()
        return createdAgent
    }

    private func makeProvider() throws -> any ModelProvider {
        guard let key = credentials.apiKey(for: providerID) else {
            throw DesktopAppError.missingCredential(providerID)
        }
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch providerID {
        case "anthropic":
            return AnthropicProvider(apiKey: key, baseURL: endpoint.isEmpty ? URL(string: "https://api.anthropic.com/v1")! : try validatedURL(endpoint))
        case "gemini":
            return GoogleGeminiProvider(apiKey: key, baseURL: endpoint.isEmpty ? URL(string: "https://generativelanguage.googleapis.com/v1beta")! : try validatedURL(endpoint))
        default:
            return OpenAICompatibleProvider(id: providerID, baseURL: endpoint.isEmpty ? URL(string: "https://api.openai.com/v1")! : try validatedURL(endpoint), apiKey: key)
        }
    }

    private func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw DesktopAppError.invalidURL(text)
        }
        return url
    }

    private func requestPermission(for request: ToolPermissionRequest) async -> ToolPermissionDecision {
        await withCheckedContinuation { continuation in
            pendingApproval = request
            permissionContinuation = continuation
        }
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(providerID, forKey: "providerID")
        defaults.set(modelID, forKey: "modelID")
        defaults.set(baseURL, forKey: "baseURL")
        defaults.set(permissionMode, forKey: "permissionMode")
        defaults.set(workingDirectoryPath, forKey: "workingDirectory")
        if let sessionID { defaults.set(sessionID, forKey: "lastSessionID") }
    }
}

private enum DesktopAppError: LocalizedError {
    case missingCredential(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            let variable = provider == "anthropic" ? "ANTHROPIC_API_KEY" : (provider == "gemini" ? "GEMINI_API_KEY" : "OPENAI_API_KEY")
            return "No credential found. Set \(variable) or add a Keychain item with service apple-agent and account \(provider)."
        case .invalidURL(let value): return "Invalid provider URL: \(value)"
        }
    }
}
