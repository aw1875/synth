import AppKit
import SwiftUI

@main
struct SynthApp: App {
    @NSApplicationDelegateAdaptor(SynthAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Synth", id: "conversation") {
            ConversationView(model: delegate.model)
                .frame(minWidth: 640, minHeight: 500)
        }
        .defaultSize(width: 900, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    Task { await delegate.model.open() }
                }
                .keyboardShortcut("n")
                .disabled(!delegate.model.canSwitch)

                Button("Open Project…", systemImage: "folder") {
                    delegate.model.chooseProject()
                }
                .keyboardShortcut("o")
                .disabled(!delegate.model.canSwitch)
            }
        }
    }
}

@MainActor
final class SynthAppDelegate: NSObject, NSApplicationDelegate {
    let model = ConversationModel()
    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            if model.anyBusy {
                let confirmation = NSAlert()
                confirmation.messageText = "Quit Synth?"
                confirmation.informativeText =
                    "Quitting will stop active work unless another client is attached."
                confirmation.addButton(withTitle: "Keep Working")
                confirmation.addButton(withTitle: "Quit Synth")
                guard confirmation.runModal() == .alertSecondButtonReturn else {
                    terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
