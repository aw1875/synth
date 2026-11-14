import SwiftUI

struct ModeControl: View {
    let model: ConversationModel
    @State private var showModes = false

    var body: some View {
        Button { showModes.toggle() } label: {
            ConversationPopoverLabel(title: modeLabel)
        }
        .accessibilityLabel("Mode")
        .accessibilityValue(modeLabel)
        .fixedSize()
        .popover(isPresented: $showModes, arrowEdge: .top) {
            ConversationPopover {
                Text("Mode").font(.headline)
                VStack(spacing: 4) {
                    ForEach(model.modes) { mode in
                        let selected = mode.id == model.state?.status?.agent
                        Button {
                            showModes = false
                            Task { await model.selectMode(mode) }
                        } label: {
                            HStack {
                                Text(mode.name)
                                Spacer()
                                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .buttonStyle(ConversationPopoverRowStyle())
            }
        }
        .onChange(of: model.sessionID) { showModes = false }
    }

    private var modeLabel: String {
        model.modes.first { $0.id == model.state?.status?.agent }?.name ?? "Mode"
    }
}

struct ConfigurationControls: View {
    let model: ConversationModel
    @State private var showModels = false
    @State private var modelListHeight: CGFloat = 300

    var body: some View {
        Button {
            showModels.toggle()
            if !model.hasRequestedModels { Task { await model.fetchModels() } }
        } label: {
            ConversationPopoverLabel(title: modelLabel)
        }
        .accessibilityLabel("Model and reasoning effort")
        .accessibilityValue(modelLabel)
        .popover(isPresented: $showModels, arrowEdge: .top) { models }
        .onChange(of: model.sessionID) { showModels = false }
    }

    private var modelLabel: String {
        guard let name = model.state?.status?.model, !name.isEmpty else { return "Model" }
        return name
    }

    private var models: some View {
        ConversationPopover(width: 300) {
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
                Text(error).foregroundStyle(SynthPalette.danger).textSelection(.enabled)
            } else if !model.loadingModels, model.state?.models?.offered.isEmpty != false {
                Text("No models available. Check the provider and refresh.").foregroundStyle(SynthPalette.muted)
            }
            if let offeredModels = model.state?.models?.offered, !offeredModels.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(offeredModels) { offered in
                            Button {
                                showModels = false
                                Task { await model.selectModel(offered) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(offered.name)
                                    Text(offered.provider).font(.caption).foregroundStyle(SynthPalette.muted)
                                }
                            }
                        }
                    }
                    .buttonStyle(ConversationPopoverRowStyle())
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { modelListHeight = $0 }
                }
                .frame(height: min(modelListHeight, 300))
            }
            if let status = model.state?.status, !status.efforts.isEmpty {
                Divider()
                ReasoningEffortControl(efforts: status.efforts, effort: status.effort) { effort in
                    await model.selectEffort(effort)
                }
                .disabled(!model.canConfigure)
            }
        }
    }
}

private struct ReasoningEffortControl: View {
    let efforts: [String]
    let effort: String
    let select: (String) async -> Void
    @State private var editing = false
    @State private var draft: Int?
    @State private var applying = false

    private var index: Int {
        if let draft, efforts.indices.contains(draft) { return draft }
        return efforts.firstIndex(of: effort) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Reasoning effort", value: efforts[index].capitalized)
                .foregroundStyle(SynthPalette.foreground)
            if efforts.count > 1 {
                Slider(value: position, in: 0...Double(efforts.count - 1), step: 1) { active in
                    editing = active
                    if !active { commit() }
                }
                .accessibilityLabel("Reasoning effort")
                .accessibilityValue(efforts[index].capitalized)
            }
        }
        .disabled(applying)
        .onChange(of: efforts) { draft = nil }
    }

    private var position: Binding<Double> {
        Binding(get: { Double(index) }, set: { value in
            guard !applying else { return }
            draft = Int(value.rounded())
            if !editing { commit() }
        })
    }

    private func commit() {
        guard !applying, let draft, efforts.indices.contains(draft) else { return }
        let selection = efforts[draft]
        guard selection != effort else {
            self.draft = nil
            return
        }
        applying = true
        Task {
            await select(selection)
            self.draft = nil
            applying = false
        }
    }
}
