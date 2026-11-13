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
        let rememberedFolder = preferences.string(forKey: "selectedProject")
        let rememberedChat = preferences.string(forKey: "selectedConversation")
        let folder = groups.compactMap(\.folder).first { $0.path == rememberedFolder }
        let hasStandaloneHistory = FileManager.default.fileExists(atPath: standaloneDirectory.path)
        guard rememberedChat != nil || groups.count > 1 || hasStandaloneHistory else { return }
        if let rememberedChat, rememberedFolder == nil || folder != nil {
            await open(in: folder, identifier: rememberedChat)
            if sessionID == nil, pendingSelection?.sessionID == nil, canSwitch {
                await open(in: folder)
            }
        } else if canSwitch {
            isOpening = true
            defer { isOpening = false }
            do {
                _ = try await connectedClient()
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        for folder in groups.map(\.folder) where sessionID == nil || folder != project {
            await loadGroup(folder, refresh: true)
        }
    }

    func register(_ folder: URL) {
        if !groups.contains(where: { $0.folder == folder }) {
            groups.append(ConversationGroup(folder: folder))
        }
    }

    func persist() {
        let preferences = UserDefaults.standard
        preferences.set(groups.compactMap { $0.folder?.path }, forKey: "projectFolders")
        preferences.set(project?.path, forKey: "selectedProject")
        preferences.set(sessionID, forKey: "selectedConversation")
    }

    private var standaloneDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Synth/Conversations", directoryHint: .isDirectory)
    }

    func workingDirectory(for folder: URL?) throws -> String {
        if let folder { return folder.path }
        let directory = standaloneDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    func loadGroup(_ folder: URL?, refresh: Bool) async {
        guard let index = groups.firstIndex(where: { $0.folder == folder }),
              !groups[index].loading, refresh || groups[index].cursor != nil else { return }
        groups[index].loading = true
        groups[index].failure = nil
        defer { groups[index].loading = false }
        do {
            guard let client, await client.connectionState == .connected else { return }
            let oldCursor = groups[index].cursor
            let cursor = refresh ? nil : oldCursor
            let page = try await client.listSessions(cwd: folder?.path ?? standaloneDirectory.path, cursor: cursor)
            let updated = Set(page.sessions.map(\.id))
            let remaining = groups[index].sessions.filter { !updated.contains($0.id) }
            groups[index].sessions = refresh ? page.sessions + remaining : remaining + page.sessions
            if !refresh || oldCursor == nil || remaining.isEmpty {
                groups[index].cursor = page.nextCursor
            }
        } catch {
            groups[index].failure = error.localizedDescription
        }
    }

    func rows(for group: ConversationGroup) -> [ConversationRow] {
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
        guard let sessionID, let client else { return }
        let folder = project
        do {
            try await client.rename(title, in: sessionID)
            await refresh(from: client)
            await loadGroup(folder, refresh: true)
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
