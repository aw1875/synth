import SwiftUI
import SynthClient
import SynthProtocol

struct ConversationView: View {
    @Bindable var model: ConversationModel
    @State private var renamePresented = false
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
        .navigationTitle(model.project?.lastPathComponent ?? "Synth")
        .navigationSubtitle(model.state?.status?.title ?? "")
        .toolbar { toolbar }
        .alert("Rename Conversation", isPresented: $renamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task { await model.rename(renameText.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: model.sessionID) {
            if model.sessionID != nil { composerFocused = true }
        }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("Start a conversation", systemImage: "bubble.left.and.bubble.right")
        } actions: {
            Button("New Conversation") { Task { await model.open() } }
                .buttonStyle(.borderedProminent)
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
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            banners
            if let identifier = model.sessionID {
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
            composer
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
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(actionTitle) { Task { await action() } }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(model.busy ? "Steer the conversation" : "Message Synth")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $model.draft)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 120)
                    .focused($composerFocused)
                    .accessibilityLabel("Message")
            }
            HStack(spacing: 12) {
                connectionLabel
                Spacer()
                if model.busy {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await model.stop() }
                    }
                    .disabled(!model.canStop)
                }
                Button(model.busy ? "Steer" : "Send", systemImage: "arrow.up") {
                    Task { await model.send() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
                .help("Send (⌘↩)")
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .frame(maxWidth: 780)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var connectionLabel: some View {
        Label(connectionText, systemImage: model.connection == .connected ? "circle.fill" : "circle.dashed")
            .font(.caption)
            .foregroundStyle(.secondary)
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

private extension ConversationView {
    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Open Project", systemImage: "folder") { model.chooseProject() }
                .disabled(!model.canSwitch)

            Button("New Conversation", systemImage: "square.and.pencil") {
                Task { await model.open() }
            }
            .disabled(!model.canSwitch)
        }
        if model.sessionID != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Rename Conversation", systemImage: "pencil") {
                    renameText = model.state?.status?.title ?? ""
                    renamePresented = true
                }
                .disabled(!model.canConfigure)
                ConfigurationControls(model: model)
                    .disabled(!model.canConfigure)
            }
        }
    }

}

private struct ConfigurationControls: View {
    let model: ConversationModel
    @State private var showModels = false

    var body: some View {
        Menu(modeLabel) {
            ForEach(model.modes) { mode in
                Button(mode.name, systemImage: mode.id == model.state?.status?.agent ? "checkmark" : "circle") {
                    Task { await model.selectMode(mode) }
                }
            }
        }
        .accessibilityLabel("Mode")
        Button {
            showModels.toggle()
            if !model.hasRequestedModels { Task { await model.fetchModels() } }
        } label: {
            Text(model.state?.status?.model.nonEmpty ?? "Model")
                .lineLimit(1)
                .frame(maxWidth: 180)
        }
        .accessibilityLabel("Model")
        .popover(isPresented: $showModels, arrowEdge: .bottom) { models }
        if let status = model.state?.status, !status.efforts.isEmpty {
            Menu(status.effort.nonEmpty ?? "Reasoning") {
                ForEach(status.efforts, id: \.self) { effort in
                    Button(effort, systemImage: effort == status.effort ? "checkmark" : "circle") {
                        Task { await model.selectEffort(effort) }
                    }
                }
            }
            .accessibilityLabel("Reasoning effort")
        }
    }

    private var modeLabel: String {
        model.modes.first { $0.id == model.state?.status?.agent }?.name ?? "Mode"
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models").font(.headline)
                Spacer()
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task { await model.fetchModels() }
                }
                .labelStyle(.iconOnly)
                .disabled(model.loadingModels)
            }
            if model.loadingModels {
                ProgressView("Finding models…").controlSize(.small)
            }
            if let error = model.modelError {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            } else if !model.loadingModels, model.state?.models?.offered.isEmpty != false {
                Text("No models available. Check the provider and refresh.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.state?.models?.offered ?? []) { offered in
                        Button {
                            showModels = false
                            Task { await model.selectModel(offered) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(offered.name)
                                Text(offered.provider).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .frame(width: 300)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
