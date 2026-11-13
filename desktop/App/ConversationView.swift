import SwiftUI
import SynthClient
import SynthProtocol

struct ConversationView: View {
    @Bindable var model: ConversationModel
    @State private var renameTarget: String?
    @State private var deleteTarget: String?
    @State private var titleActionsPresented = false
    @State private var renameText = ""
    @State private var scrollAnchors: [String: TranscriptAnchor] = [:]
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(model: model)
        } detail: {
            detail
        }
        .task { await model.restore() }
    }

    private var detail: some View {
        Group {
            if model.sessionID != nil {
                conversation
            } else if model.isOpening || model.error != nil {
                opening
            } else {
                welcome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SynthPalette.background)
        .foregroundStyle(SynthPalette.foreground)
        .navigationTitle(conversationTitle)
        .toolbar(removing: model.sessionID == nil ? nil : .title)
        .toolbar {
            if let identifier = model.sessionID {
                ToolbarItem(placement: .navigation) { titleMenu(for: identifier) }
            }
        }
        .alert("Rename Conversation", isPresented: isPresenting($renameTarget)) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let identifier = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await model.rename(name, in: identifier) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete Conversation?", isPresented: isPresenting($deleteTarget)) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let identifier = deleteTarget else { return }
                Task {
                    if await model.deleteConversation(identifier) { scrollAnchors.removeValue(forKey: identifier) }
                }
            }
        } message: {
            Text("This permanently removes the conversation and its saved history.")
        }
        .onChange(of: model.sessionID) {
            titleActionsPresented = false
            if model.sessionID != nil { composerFocused = true }
        }
    }

    private var conversationTitle: String {
        guard model.sessionID != nil else { return "Synth" }
        return model.state?.status?.title.nonEmpty ?? "Untitled conversation"
    }

    private func isPresenting(_ target: Binding<String?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } })
    }

    private func titleMenu(for identifier: String) -> some View {
        Button { titleActionsPresented.toggle() } label: {
            ConversationPopoverLabel(title: conversationTitle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .popover(isPresented: $titleActionsPresented, arrowEdge: .bottom) {
            ConversationPopover {
                VStack(spacing: 4) {
                    Button("Rename…", systemImage: "pencil") {
                        titleActionsPresented = false
                        renameText = model.state?.status?.title ?? ""
                        renameTarget = identifier
                    }
                    .disabled(!model.canConfigure)
                    Button("Delete…", systemImage: "trash", role: .destructive) {
                        titleActionsPresented = false
                        deleteTarget = identifier
                    }
                    .disabled(!model.canDelete)
                }
                .buttonStyle(ConversationPopoverRowStyle())
            }
        }
        .accessibilityHint("Conversation actions")
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("Start a conversation", systemImage: "bubble.left.and.bubble.right")
        } actions: {
            Button("New Conversation") { Task { await model.open() } }
                .buttonStyle(SynthProminentButtonStyle())
            Button("Open Project…", action: model.chooseProject)
        }
    }

    private var opening: some View {
        Group {
            if model.isOpening {
                ProgressView("Connecting to Synth…")
            } else {
                ContentUnavailableView {
                    Label("Couldn't open a conversation", systemImage: "exclamationmark.circle")
                } description: {
                    if let error = model.error { Text(error).textSelection(.enabled) }
                } actions: {
                    Button("Retry") { Task { await model.reconnect() } }
                        .buttonStyle(SynthProminentButtonStyle())
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            banners
            if let identifier = model.sessionID {
                if model.messages.isEmpty, model.state?.stream == nil, model.interactions.isEmpty {
                    emptyConversation
                } else {
                    TranscriptView(
                        sessionID: identifier,
                        messages: model.messages,
                        stream: model.state?.stream,
                        notices: model.state?.notices ?? [],
                        interactions: model.interactions,
                        model: model,
                        anchor: Binding(
                            get: { scrollAnchors[identifier] },
                            set: { scrollAnchors[identifier] = $0 }
                        )
                    )
                    .id(identifier)
                }
            }
            composer
        }
    }

    private var emptyConversation: some View {
        let prompt = model.project == nil ? "Ask a question or describe a task." :
            "Ask about your project or describe a change."
        return ContentUnavailableView(
            "Start a conversation",
            systemImage: "bubble.left.and.text.bubble.right",
            description: Text(prompt)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notices = model.state?.notices, !notices.isEmpty {
                ScrollView { TranscriptNotices(notices: notices) }
                    .frame(maxWidth: 730, maxHeight: 54)
                    .padding(.horizontal, 24)
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let failure = connectionFailure {
            banner(failure, actionTitle: "Reconnect") { await model.reconnect() }
        } else if model.state?.status?.providerMissing == true {
            banner("Set up a provider by running synth in Terminal.", actionTitle: "Retry") {
                await model.retryProvider()
            }
        } else if let error = model.error {
            banner(error, actionTitle: "Dismiss") { model.error = nil }
        }
    }

    private var connectionFailure: String? {
        if let failure = model.state?.failure { return failure }
        if case .failed(let message) = model.connection { return message }
        return nil
    }

    private func banner(
        _ text: String, actionTitle: String, action: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(SynthPalette.accent)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(actionTitle) { Task { await action() } }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(SynthPalette.alternateSurface)
    }

}

extension ConversationView {
    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            composerInput
            HStack(spacing: 12) {
                connectionLabel
                ModeControl(model: model)
                    .disabled(!model.canConfigure)
                Spacer()
                ConfigurationControls(model: model)
                    .disabled(!model.canConfigure)
                if model.busy {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await model.stop() }
                    }
                    .disabled(!model.canStop)
                }
                Button {
                    Task { await model.send() }
                } label: {
                    Label(model.busy ? "Steer" : "Send", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(SynthProminentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
                .help(model.busy ? "Steer (⌘↩)" : "Send (⌘↩)")
            }
        }
        .padding(14)
        .background(SynthPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SynthPalette.border))
        .frame(maxWidth: 780)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var composerInput: some View {
        Text(model.draft + "\u{200B}")
            .lineLimit(6)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
            .overlay {
                TextEditor(text: $model.draft)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(SynthPalette.foreground)
                    .focused($composerFocused)
                    .accessibilityLabel("Message")
            }
            .overlay(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(model.busy ? "Steer the conversation" : "Message Synth")
                        .foregroundStyle(SynthPalette.muted)
                        .padding(.top, 4)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .font(.body)
    }

    private var connectionLabel: some View {
        Label {
            Text(connectionText).lineLimit(1)
        } icon: {
            if model.connection == .connected {
                Image(systemName: "circle.fill").foregroundStyle(SynthPalette.success)
            } else {
                Image(systemName: "circle.dashed")
            }
        }
        .font(.caption)
        .foregroundStyle(SynthPalette.muted)
    }

    private var connectionText: String {
        if model.isOpening { return "Opening conversation…" }
        if model.busy, let label = model.state?.status?.label, !label.isEmpty { return label }
        switch model.connection {
        case .connected: return model.busy ? "Working…" : "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .failed, .disconnected: return "Disconnected"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
