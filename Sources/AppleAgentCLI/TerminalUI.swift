import Foundation
import PiTypes
import PiAgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

actor TerminalApprovalBroker {
    private var pending: [String: CheckedContinuation<ToolPermissionDecision, Never>] = [:]

    func request(_ request: ToolPermissionRequest, cancellation: CancellationToken) async -> ToolPermissionDecision {
        guard !cancellation.isCancelled else { return .deny }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[request.id] = continuation
                Task {
                    try? await Task.sleep(for: .seconds(60))
                    self.resolve(id: request.id, decision: .deny)
                }
            }
        } onCancel: {
            Task { await self.resolve(id: request.id, decision: .deny) }
        }
    }

    @discardableResult
    func resolve(id: String, decision: ToolPermissionDecision) -> Bool {
        guard let continuation = pending.removeValue(forKey: id) else { return false }
        continuation.resume(returning: decision)
        return true
    }
}

private actor TerminalState {
    struct Snapshot: Sendable {
        var transcript: [String]
        var streamingText: String
        var status: String
        var running: Bool
        var permission: ToolPermissionRequest?
    }

    private var transcript: [String] = []
    private var streamingText = ""
    private var status = "Ready"
    private var running = false
    private var permission: ToolPermissionRequest?

    func begin(_ prompt: String) {
        transcript.append("You: \(prompt)")
        streamingText = ""
        status = "Thinking…"
        running = true
    }

    func consume(_ event: AgentEvent, approval: TerminalApprovalBroker) async {
        switch event {
        case .textDelta(_, let delta): streamingText += delta
        case .toolStart(let call): status = "Running tool: \(call.name)"
        case .permissionRequest(let request): permission = request; status = "Approval required"
        case .messageEnd(let message):
            if message.role == .assistant {
                if !streamingText.isEmpty { transcript.append("Assistant: \(streamingText)") }
                else if !message.text.isEmpty { transcript.append("Assistant: \(message.text)") }
                streamingText = ""
            } else if message.role == .toolResult {
                let tag = message.isError == true ? "Tool error" : "Tool"
                transcript.append("\(tag): \(message.text)")
            }
        case .toolEnd(_, let result): status = result.isError ? "Tool failed" : "Tool finished"
        case .failed(let code, let message): transcript.append("Error (\(code)): \(message)"); status = "Error"
        case .agentSettled: running = false; permission = nil; status = "Ready"
        default: break
        }
    }

    func end() { running = false; permission = nil; status = "Ready" }
    func snapshot() -> Snapshot { Snapshot(transcript: transcript, streamingText: streamingText, status: status, running: running, permission: permission) }
}

/// Full-screen ANSI terminal view. Non-TTY input is handled by the CLI's line-oriented fallback.
enum TerminalUI {
    static func run(agent: Agent, approval: TerminalApprovalBroker, firstPrompt: String?) async {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            print("AppleAgent TUI needs an interactive terminal; use --mode print for piped input.")
            return
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
        FileHandle.standardOutput.write(Data("\u{1B}[?1049h\u{1B}[?25l".utf8))
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            FileHandle.standardOutput.write(Data("\u{1B}[?25h\u{1B}[?1049l\n".utf8))
        }

        let state = TerminalState()
        var input: [Character] = []
        var cursor = 0
        var history: [String] = []
        var historyIndex: Int?
        var task: Task<Void, Never>?
        var shouldExit = false
        if let firstPrompt, !firstPrompt.isEmpty { task = startTurn(firstPrompt, agent: agent, state: state, approval: approval) }
        draw(state: await state.snapshot(), input: input, cursor: cursor)

        while !shouldExit {
            let data = FileHandle.standardInput.readData(ofLength: 1)
            if data.isEmpty {
                draw(state: await state.snapshot(), input: input, cursor: cursor)
                continue
            }
            let byte = data[0]
            if byte == 0x03 {
                if (await state.snapshot()).running { await agent.abort() }
                else { shouldExit = true }
            } else if byte == 0x04 {
                if input.isEmpty { shouldExit = true }
            } else if byte == 0x1B {
                let sequence = FileHandle.standardInput.readData(ofLength: 2)
                if sequence.count == 2, sequence[0] == 0x5B {
                    switch sequence[1] {
                    case 0x44: cursor = max(0, cursor - 1)
                    case 0x43: cursor = min(input.count, cursor + 1)
                    case 0x41:
                        if !history.isEmpty { historyIndex = max(0, (historyIndex ?? history.count) - 1); input = Array(history[historyIndex!]); cursor = input.count }
                    case 0x42:
                        if let index = historyIndex {
                            if index + 1 < history.count { historyIndex = index + 1; input = Array(history[index + 1]) }
                            else { historyIndex = nil; input = [] }
                            cursor = input.count
                        }
                    default: break
                    }
                }
            } else if byte == 0x7F || byte == 0x08 {
                if cursor > 0 { input.remove(at: cursor - 1); cursor -= 1 }
            } else if byte == 0x0D || byte == 0x0A {
                let current = String(input).trimmingCharacters(in: .whitespacesAndNewlines)
                let snapshot = await state.snapshot()
                if let request = snapshot.permission {
                    let decision: ToolPermissionDecision
                    switch current.lowercased() {
                    case "y", "yes": decision = .allowOnce
                    case "s", "session": decision = .allowForSession
                    case "p", "project": decision = .allowForProject
                    default: decision = .deny
                    }
                    _ = await approval.resolve(id: request.id, decision: decision)
                    input = []; cursor = 0
                } else if current == "/exit" || current == "/quit" {
                    shouldExit = true
                } else if current == "/help" {
                    let commands = await agent.commandNames().map { "/\($0)" }.joined(separator: ", ")
                    await state.appendLine("Commands: /help, /clear, /exit, /quit" + (commands.isEmpty ? "" : ", \(commands)") + ". Enter sends a prompt; Ctrl-C cancels a running turn.")
                    input = []; cursor = 0
                } else if current == "/clear" {
                    await state.clear()
                    input = []; cursor = 0
                } else if current.hasPrefix("/"), !snapshot.running {
                    let parts = current.dropFirst().split(whereSeparator: \.isWhitespace).map(String.init)
                    if let commandName = parts.first {
                        do {
                            if let output = try await agent.executeCommand(commandName, arguments: Array(parts.dropFirst())) {
                                if await agent.commandSendsResultToAgent(commandName) {
                                    history.append(output); historyIndex = nil
                                    task = startTurn(output, agent: agent, state: state, approval: approval)
                                } else {
                                    await state.appendLine(output)
                                }
                            } else {
                                await state.appendLine("Unknown command: /\(commandName)")
                            }
                        } catch {
                            await state.appendLine("Command error: \(error.localizedDescription)")
                        }
                    }
                    input = []; cursor = 0
                } else if !current.isEmpty, !snapshot.running {
                    history.append(current); historyIndex = nil
                    input = []; cursor = 0
                    task = startTurn(current, agent: agent, state: state, approval: approval)
                }
            } else if byte >= 0x20 {
                var utf8 = Data([byte])
                let expected = byte < 0x80 ? 1 : (byte & 0xE0 == 0xC0 ? 2 : (byte & 0xF0 == 0xE0 ? 3 : 4))
                if expected > 1 { utf8.append(FileHandle.standardInput.readData(ofLength: expected - 1)) }
                if let scalar = String(data: utf8, encoding: .utf8) { input.insert(contentsOf: scalar, at: cursor); cursor += scalar.count }
            }
            if shouldExit { break }
            draw(state: await state.snapshot(), input: input, cursor: cursor)
            if task?.isCancelled == true { task = nil }
        }
        if (await state.snapshot()).running { await agent.abort() }
        await task?.value
    }

    private static func startTurn(_ prompt: String, agent: Agent, state: TerminalState,
                                  approval: TerminalApprovalBroker) -> Task<Void, Never> {
        Task {
            await state.begin(prompt)
            for await event in await agent.events(for: prompt) { await state.consume(event, approval: approval) }
            await state.end()
        }
    }

    private static func draw(state: TerminalState.Snapshot, input: [Character], cursor: Int) {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        let rows = max(12, Int(size.ws_row))
        let columns = max(40, Int(size.ws_col))
        let transcriptRows = max(4, rows - 7)
        var lines = ["AppleAgent  ·  \(state.status)", String(repeating: "─", count: columns)]
        var transcript = state.transcript.flatMap { wrap($0, width: columns - 2) }
        if !state.streamingText.isEmpty { transcript += wrap("Assistant: \(state.streamingText)", width: columns - 2) }
        if let permission = state.permission {
            let args = String(data: permission.arguments.encodedData, encoding: .utf8) ?? "{}"
            transcript += wrap("APPROVAL: \(permission.toolName) [\(permission.permission.rawValue)] \(args)", width: columns - 2)
            transcript += ["Press y once, s for this session, p for this project, n/Enter to deny."]
        }
        lines += transcript.suffix(transcriptRows).map { "  " + $0 }
        if lines.count < 2 + transcriptRows { lines += Array(repeating: "", count: 2 + transcriptRows - lines.count) }
        lines += [String(repeating: "─", count: columns), "› " + String(input)]
        lines += ["Enter: send  ·  ↑/↓: history  ·  Ctrl-C: cancel/exit  ·  /help"]
        let screen = lines.prefix(rows).map { String($0.prefix(columns)) }.joined(separator: "\r\n")
        let moveLeft = max(0, input.count - cursor)
        let frame = "\u{1B}[H\u{1B}[2J" + screen + "\u{1B}[?25l" + (moveLeft > 0 ? "\u{1B}[\(moveLeft)D" : "")
        FileHandle.standardOutput.write(Data(frame.utf8))
    }

    private static func wrap(_ value: String, width: Int) -> [String] {
        guard width > 0 else { return [value] }
        var result: [String] = []
        for paragraph in value.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            for character in paragraph {
                if current.count >= width { result.append(current); current = "" }
                current.append(character)
            }
            result.append(current)
        }
        return result
    }
}

private extension TerminalState {
    func appendLine(_ line: String) { transcript.append(line) }
    func clear() { transcript.removeAll(); streamingText = "" }
}
