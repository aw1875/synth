import SwiftUI

struct ProjectSidebar: View {
    let model: ConversationModel
    @State private var collapsedProjects: Set<URL> = []

    var body: some View {
        List {
            Section {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    Task { await model.open() }
                }
                Button("Open Project…", systemImage: "folder.badge.plus", action: model.chooseProject)
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
                    .foregroundStyle(.primary)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 340)
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
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("Retry") { Task { await model.loadGroup(group.folder, refresh: true) } }
        } else if group.cursor != nil {
            Button("More Conversations") { Task { await model.loadGroup(group.folder, refresh: false) } }
        }
    }

    private func conversation(_ row: ConversationRow, in group: ConversationGroup) -> some View {
        let current = model.activity[row.id]
        let title = [current?.title, row.stored?.title].compactMap { $0 }.first { !$0.isEmpty }
        return Button {
            Task { await model.open(in: group.folder, stored: row.stored, identifier: row.id) }
        } label: {
            HStack {
                Text(title ?? "Untitled conversation").lineLimit(1)
                Spacer()
                if current?.awaitingInput == true {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Waiting for input")
                } else if current?.busy == true {
                    ProgressView().controlSize(.mini).accessibilityLabel("Running")
                } else if model.completed.contains(row.id) {
                    Image(systemName: "checkmark.circle").accessibilityLabel("Completed")
                } else if current?.failed == true {
                    Image(systemName: "exclamationmark.circle").accessibilityLabel("Disconnected")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .background(
                row.id == model.sessionID ? Color.accentColor.opacity(0.18) : .clear,
                in: .rect(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canSwitch)
        .accessibilityAddTraits(row.id == model.sessionID ? .isSelected : [])
    }
}
