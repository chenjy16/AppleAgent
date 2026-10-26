import SwiftUI
import AppKit
import PiTypes
import PiAgentCore

struct ConversationView: View {
    @ObservedObject var model: DesktopAgentModel
    @State private var prompt = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(item: $model.pendingApproval) { request in
            PermissionApprovalView(request: request) { decision in
                model.resolvePermission(decision)
            }
        }
        .alert("AppleAgent", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.terminal.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AppleAgent").font(.headline)
                Text(URL(fileURLWithPath: model.workingDirectoryPath).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button { model.chooseWorkingDirectory() } label: {
                Label("Folder", systemImage: "folder")
            }
            .help("Choose working folder")
            Button { model.startNewSession() } label: {
                Label("New", systemImage: "square.and.pencil")
            }
            .disabled(model.isRunning)
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty && model.streamingText.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkle").font(.system(size: 34)).foregroundStyle(.tint)
                            Text("Start a conversation").font(.title3.weight(.semibold))
                            Text("Ask about your project or request a change.").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }
                    ForEach(model.messages.filter { $0.role == .user || $0.role == .assistant }) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if model.isRunning, !model.streamingText.isEmpty {
                        MessageBubble(message: ConversationMessage(role: .assistant, text: model.streamingText))
                            .id("streaming")
                    }
                    if model.isRunning && model.streamingText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.activity).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 48)
                        .id("streaming")
                    }
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.streamingText) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("streaming", anchor: .bottom) }
            }
            .onChange(of: model.messages.count) { _ in
                if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message AppleAgent…", text: $prompt, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                .onSubmit { sendPrompt() }
                .disabled(model.isRunning)
            if model.isRunning {
                Button { model.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop generation")
            } else {
                Button(action: sendPrompt) { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send message")
            }
        }
        .padding(16)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2.bold())
            Form {
                Picker("Provider", selection: $model.providerID) {
                    ForEach(model.providerOptions, id: \.id) { option in Text(option.title).tag(option.id) }
                }
                HStack {
                    TextField("Model ID", text: $model.modelID)
                    Button(model.isLoadingModels ? "Loading…" : "Refresh") { model.loadModels() }
                        .disabled(model.isLoadingModels || !model.hasCredential)
                }
                if !model.availableModels.isEmpty {
                    Picker("Available models", selection: $model.modelID) {
                        ForEach(model.availableModels) { item in Text(item.id).tag(item.id) }
                    }
                }
                TextField("API Base URL (optional)", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
                Picker("Tool permissions", selection: $model.permissionMode) {
                    Text("Ask before tools").tag("ask")
                    Text("Read-only tools").tag("read-only")
                    Text("Allow all tools").tag("allow")
                    Text("Deny all tools").tag("deny")
                }
                HStack {
                    Image(systemName: model.hasCredential ? "checkmark.circle.fill" : "key.slash")
                        .foregroundStyle(model.hasCredential ? .green : .secondary)
                    Text(model.hasCredential ? "Credential found in environment or Keychain" : "No provider credential found")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("API keys are read from environment variables or the apple-agent Keychain. They are never stored in app preferences.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func sendPrompt() {
        let value = prompt
        prompt = ""
        model.send(value)
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    private var isUser: Bool { message.role == .user }

    private var attributedText: AttributedString {
        if message.text.isEmpty { return AttributedString(" ") }
        do {
            return try AttributedString(markdown: message.text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full))
        } catch {
            return AttributedString(message.text)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isUser ? "person.crop.circle.fill" : "sparkle")
                .font(.title3)
                .foregroundStyle(isUser ? Color.secondary : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(isUser ? "You" : "AppleAgent")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text(attributedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(message.toolCalls) { call in
                    Label(call.name, systemImage: "wrench.and.screwdriver")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(isUser ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PermissionApprovalView: View {
    let request: ToolPermissionRequest
    let decide: (ToolPermissionDecision) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Tool approval required", systemImage: "hand.raised.fill")
                .font(.title2.bold())
            Text(request.toolName).font(.headline.monospaced())
            Text("Permission: \(request.permission.rawValue)").foregroundStyle(.secondary)
            ScrollView {
                Text(String(data: request.arguments.encodedData, encoding: .utf8) ?? "{}")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 180)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Deny", role: .destructive) { finish(.deny) }
                Spacer()
                Button("Allow Once") { finish(.allowOnce) }
                Button("Allow Session") { finish(.allowForSession) }
                    .buttonStyle(.borderedProminent)
                Button("Allow Project") { finish(.allowForProject) }
            }
        }
        .padding(24)
        .frame(width: 620, height: 420)
    }

    private func finish(_ decision: ToolPermissionDecision) {
        decide(decision)
        dismiss()
    }
}
