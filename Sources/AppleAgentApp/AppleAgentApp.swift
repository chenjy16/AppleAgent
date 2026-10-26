import SwiftUI
import AppKit

@main
struct AppleAgentApp: App {
    @StateObject private var model = DesktopAgentModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ConversationView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.startNewSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
