import SwiftUI

struct ProjectSidebar: View {
    let model: ConversationModel

    var body: some View {
        List {
            ForEach(model.groups) { group in
                Section {
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
                } header: {
                    HStack {
                        if let folder = group.folder {
                            Text(folder.lastPathComponent).help(folder.path).lineLimit(1)
                        } else {
                            Text("Conversations")
                        }
                        Spacer()
                        Button("New Conversation", systemImage: "plus") {
                            Task { await model.open(in: group.folder) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!model.canSwitch)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 340)
        .safeAreaInset(edge: .bottom) {
            Button("Open Project…", systemImage: "folder.badge.plus", action: model.chooseProject)
                .buttonStyle(.borderless)
                .disabled(!model.canSwitch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
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
