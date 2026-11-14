import SwiftUI

struct ProjectSidebar: View {
    let model: ConversationModel
    @State private var collapsedProjects: Set<URL> = []

    var body: some View {
        List {
            Section {
                Button {
                    Task { await model.open() }
                } label: {
                    sidebarAction("New Conversation", symbol: "square.and.pencil")
                }
                Button(action: model.chooseProject) {
                    sidebarAction("Open Project…", symbol: "folder.badge.plus")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!model.canSwitch)
            ForEach(model.groups) { group in
                Section {
                    if group.folder.map(collapsedProjects.contains) != true { rows(in: group) }
                } header: {
                    HStack {
                        if let folder = group.folder {
                            projectHeading(folder)
                            Spacer()
                            Button("New Project Conversation", systemImage: "plus") {
                                collapsedProjects.remove(folder)
                                Task { await model.open(in: folder) }
                            }
                            .font(.body.weight(.semibold))
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .padding(.trailing, 8)
                            .disabled(!model.canSwitch)
                        } else {
                            Text("Conversations")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SynthPalette.foreground)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SynthPalette.surface)
        .foregroundStyle(SynthPalette.foreground)
        .navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 340)
    }

    private func sidebarAction(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(SynthPalette.accent)
        }
    }

    private func projectHeading(_ folder: URL) -> some View {
        let collapsed = collapsedProjects.contains(folder)
        return Button {
            if collapsed { collapsedProjects.remove(folder) } else { collapsedProjects.insert(folder) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 9)
                Text(folder.lastPathComponent).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(folder.path)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }

    @ViewBuilder
    private func rows(in group: ConversationGroup) -> some View {
        ForEach(model.rows(for: group)) { row in
            conversation(row, in: group)
        }
        if group.loading {
            ProgressView().controlSize(.small)
        } else if let error = group.failure {
            Text(error).font(.caption).foregroundStyle(SynthPalette.danger)
            Button("Retry") { Task { await model.loadGroup(group.folder, refresh: true) } }
        } else if group.cursor != nil {
            Button("More Conversations") { Task { await model.loadGroup(group.folder, refresh: false) } }
        }
    }

    private func conversation(_ row: ConversationRow, in group: ConversationGroup) -> some View {
        let current = model.activity[row.id]
        let title = [current?.title, row.stored?.title].compactMap { $0 }.first { !$0.isEmpty }
        let selected = row.id == model.sessionID
        return Button {
            Task { await model.open(in: group.folder, stored: row.stored, identifier: row.id) }
        } label: {
            HStack {
                Text(title ?? "Untitled conversation").lineLimit(1)
                Spacer()
                if current?.awaitingInput == true {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(SynthPalette.accent)
                        .accessibilityLabel("Waiting for input")
                } else if current?.busy == true {
                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                } else if model.completed.contains(row.id) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(SynthPalette.success)
                        .accessibilityLabel("Completed")
                } else if current?.failed == true {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(SynthPalette.danger)
                        .accessibilityLabel("Disconnected")
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? SynthPalette.accent : SynthPalette.foreground)
            .background(
                selected ? SynthPalette.alternateSurface : .clear,
                in: .rect(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canSwitch)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
