import Foundation
import SynthProtocol

extension ConversationModel {
    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        let preferences = UserDefaults.standard
        for path in preferences.stringArray(forKey: "projectFolders") ?? [] {
            register(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        }
        guard !projects.isEmpty else { return }
        let rememberedFolder = preferences.string(forKey: "selectedProject")
        let rememberedChat = preferences.string(forKey: "selectedConversation")
        do {
            _ = try await connectedClient()
        } catch {
            self.error = error.localizedDescription
            return
        }
        for folder in projects.map(\.folder) {
            await loadProject(folder, refresh: true)
        }
        if let folder = projects.first(where: { $0.folder.path == rememberedFolder })?.folder {
            await open(in: folder, identifier: rememberedChat)
            if sessionID == nil, rememberedChat != nil { await open(in: folder) }
        }
    }

    func register(_ folder: URL) {
        if !projects.contains(where: { $0.folder == folder }) {
            projects.append(ProjectGroup(folder: folder))
        }
    }

    func persist() {
        let preferences = UserDefaults.standard
        preferences.set(projects.map(\.folder.path), forKey: "projectFolders")
        preferences.set(project?.path, forKey: "selectedProject")
        preferences.set(sessionID, forKey: "selectedConversation")
    }

    func loadProject(_ folder: URL, refresh: Bool) async {
        guard let index = projects.firstIndex(where: { $0.folder == folder }),
              !projects[index].loading, refresh || projects[index].cursor != nil else { return }
        projects[index].loading = true
        projects[index].failure = nil
        defer { projects[index].loading = false }
        do {
            guard let client, await client.connectionState == .connected else { return }
            let oldCursor = projects[index].cursor
            let cursor = refresh ? nil : oldCursor
            let page = try await client.listSessions(cwd: folder.path, cursor: cursor)
            let updated = Set(page.sessions.map(\.id))
            let remaining = projects[index].sessions.filter { !updated.contains($0.id) }
            projects[index].sessions = refresh ? page.sessions + remaining : remaining + page.sessions
            if !refresh || oldCursor == nil || remaining.isEmpty {
                projects[index].cursor = page.nextCursor
            }
        } catch {
            projects[index].failure = error.localizedDescription
        }
    }

    func rows(for group: ProjectGroup) -> [ConversationRow] {
        let stored = Set(group.sessions.map(\.id))
        let opened = openedSessions.values
            .filter { $0.folder == group.folder && !stored.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map { ConversationRow(id: $0.id, stored: nil) }
        return opened + group.sessions.map { ConversationRow(id: $0.id, stored: $0) }
    }

    func loadOlder() async {
        guard let sessionID, let client, let first = messages.first, hasOlderMessages,
              loadingHistory.insert(sessionID).inserted else { return }
        defer { loadingHistory.remove(sessionID) }
        do {
            let page = try await client.history(before: first.seq, in: sessionID)
            let existing = historyBySession[sessionID, default: []]
            let seen = Set(existing.map(\.seq))
            let loaded = page.filter { $0.seq < first.seq && !seen.contains($0.seq) }
            historyBySession[sessionID] = (loaded + existing).sorted { $0.seq < $1.seq }
        } catch {
            if self.sessionID == sessionID { self.error = error.localizedDescription }
        }
    }

    func rename(_ title: String) async {
        guard let sessionID, let client, let folder = project else { return }
        do {
            try await client.rename(title, in: sessionID)
            await refresh(from: client)
            await loadProject(folder, refresh: true)
        } catch {
            if self.sessionID == sessionID { self.error = error.localizedDescription }
        }
    }

    func fullThinking(_ message: Synth.Message, in sessionID: String) async throws -> String {
        guard let client else { return message.thinking ?? "" }
        return try await client.thinking(sequence: message.seq, in: sessionID)
    }

    func fullToolResult(sequence: UInt64, call index: Int, in sessionID: String) async throws -> String {
        guard let client else { return "" }
        return try await client.toolResult(sequence: sequence, call: index, in: sessionID)
    }
}

struct ConversationRow: Identifiable {
    let id: String
    let stored: ACP.SessionInfo?
}
