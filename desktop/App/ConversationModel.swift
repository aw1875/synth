import AppKit
import Observation
import SynthClient
import SynthProtocol

@MainActor
@Observable
final class ConversationModel {
    private(set) var project: URL?
    private(set) var sessionID: String?
    private(set) var state: SessionState?
    private(set) var interactions: [Interaction] = []
    var groups = [ConversationGroup(folder: nil)]
    private(set) var pendingSelection: ConversationSelection?
    var activity: [String: SynthClient.Activity] = [:]
    var completed: Set<String> = []
    var loadingHistory: Set<String> = []
    var openedSessions: [String: OpenedConversation] = [:]
    var historyBySession: [String: [Synth.Message]] = [:]
    var drafts: [String: String] = [:]
    var failures: [String: String] = [:]
    var didRestore = false
    private(set) var modes: [ACP.Mode] = []
    private(set) var connection: SynthClient.ConnectionState = .disconnected
    var isOpening = false
    private(set) var isShuttingDown = false
    private(set) var isUpdatingConfiguration = false
    private(set) var modelError: String?
    private(set) var isFetchingModels = false
    private var modelsRequested = false
    private var submissions: [String: Int] = [:]
    private var stopping: Set<String> = []
    var client: SynthClient?
    private var observing: Task<Void, Never>?

    var draft: String {
        get { sessionID.flatMap { drafts[$0] } ?? "" }
        set { if let sessionID { drafts[sessionID] = newValue } }
    }

    private var submitting: Int { sessionID.flatMap { submissions[$0] } ?? 0 }
    private var stopRequested: Bool { sessionID.map(stopping.contains) ?? false }
    var anyBusy: Bool { submissions.values.contains { $0 > 0 } || activity.values.contains(where: \.busy) }
    var recentSessions: [ACP.SessionInfo] { groups.first(where: { $0.folder == project })?.sessions ?? [] }
    var olderMessages: [Synth.Message] {
        guard let sessionID, let first = state?.messages.first?.seq else { return [] }
        return historyBySession[sessionID, default: []].filter { $0.seq < first }
    }
    var hasOlderMessages: Bool { (state?.dropped ?? 0) > UInt64(olderMessages.count) }
    var messages: [Synth.Message] { olderMessages + (state?.messages ?? []) }
    var error: String?

    var busy: Bool {
        submitting > 0 || (connection == .connected && state?.failure == nil && state?.status?.isBusy == true)
    }
    var canSwitch: Bool { !isOpening && !isShuttingDown }
    var canSend: Bool {
        connection == .connected && sessionID != nil && !isOpening && !isShuttingDown &&
            !isUpdatingConfiguration && state?.failure == nil &&
            state?.status?.providerMissing == false && !stopRequested &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canStop: Bool {
        connection == .connected && sessionID != nil && busy && !stopRequested && state?.failure == nil
    }
    var canConfigure: Bool {
        sessionID != nil && connection == .connected && !busy && !isOpening &&
            !isUpdatingConfiguration && !isFetchingModels && state?.failure == nil
    }
    var loadingModels: Bool { isFetchingModels || (state?.models?.pending ?? 0) > 0 }

    func chooseProject() {
        guard canSwitch else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let directory = panel.url else { return }
                Task { await self?.openProject(directory) }
            }
        } else {
            panel.begin { [weak self] response in
                guard response == .OK, let directory = panel.url else { return }
                Task { await self?.openProject(directory) }
            }
        }
    }

    private func openProject(_ directory: URL) async {
        guard canSwitch else { return }
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL
        register(folder)
        await open(in: folder)
    }

    func open(in folder: URL? = nil, stored: ACP.SessionInfo? = nil, identifier: String? = nil) async {
        guard canSwitch else { return }
        let target = stored?.id ?? identifier
        pendingSelection = ConversationSelection(folder: folder, sessionID: target)
        isOpening = true
        defer { isOpening = false }
        do {
            let client = try await connectedClient()
            let opened = try await obtainSession(target, in: folder, stored: stored, client: client)
            select(opened)
            await refresh(from: client)
            await loadGroup(folder, refresh: true)
        } catch {
            self.error = error.localizedDescription
            if let rpcError = error as? RPCError, rpcError.message == "no such session" {
                pendingSelection = ConversationSelection(folder: folder, sessionID: nil)
            }
        }
    }

    private func obtainSession(
        _ identifier: String?, in folder: URL?, stored: ACP.SessionInfo?, client: SynthClient
    ) async throws -> OpenedConversation {
        if let identifier, let opened = openedSessions[identifier],
           let state = await client.sessions[identifier], state.failure == nil {
            return opened
        }
        let cwd = try stored?.cwd ?? identifier.flatMap { openedSessions[$0]?.cwd } ?? workingDirectory(for: folder)
        let setup: ACP.SessionOpened
        let openedID: String
        if let identifier {
            setup = try await client.loadSession(identifier, cwd: cwd)
            openedID = identifier
        } else {
            setup = try await client.newSession(cwd: cwd)
            guard let identifier = setup.sessionId else {
                throw SynthClient.Failure.invalidResponse("missing session ID")
            }
            openedID = identifier
        }
        let modes = setup.modes?.availableModes ?? []
        let opened = OpenedConversation(id: openedID, folder: folder, cwd: cwd, modes: modes)
        openedSessions[openedID] = opened
        if let folder { register(folder) }
        return opened
    }

    private func select(_ opened: OpenedConversation) {
        project = opened.folder
        sessionID = opened.id
        pendingSelection = nil
        modes = opened.modes
        completed.remove(opened.id)
        error = failures[opened.id]
        modelError = nil
        modelsRequested = false
        persist()
    }

    func refreshHistory() async {
        await loadGroup(project, refresh: true)
    }

    func reconnect() async {
        guard !isOpening else { return }
        guard let client, let sessionID else {
            await open(in: pendingSelection?.folder, identifier: pendingSelection?.sessionID)
            for folder in groups.compactMap(\.folder) {
                await loadGroup(folder, refresh: true)
            }
            return
        }
        isOpening = true
        error = nil
        defer { isOpening = false }
        do {
            let setup: ACP.SessionOpened?
            if await client.connectionState == .connected, let opened = openedSessions[sessionID] {
                setup = try await client.loadSession(sessionID, cwd: opened.cwd)
            } else {
                let failures = try await client.reconnect()
                error = failures[sessionID]
                setup = nil
            }
            if let modes = setup?.modes?.availableModes { self.modes = modes }
            modelsRequested = false
            modelError = nil
            await refresh(from: client)
            await refreshHistory()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connectedClient() async throws -> SynthClient {
        guard !isShuttingDown else { throw SynthClient.Failure.disconnected }
        let engine: SynthClient
        if let client {
            engine = client
        } else {
            let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/synth")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw SynthClient.Failure.invalidResponse("the bundled Synth engine is missing")
            }
            let environment = await LoginEnvironment.load()
            guard !isShuttingDown else { throw SynthClient.Failure.disconnected }
            engine = SynthClient(
                executable: executable,
                directory: FileManager.default.homeDirectoryForCurrentUser,
                environment: environment
            )
            client = engine
            observe(engine)
        }
        if await engine.connectionState != .connected {
            if openedSessions.isEmpty {
                try await engine.connect()
            } else {
                _ = try await engine.reconnect()
            }
        }
        connection = .connected
        return engine
    }

    private func observe(_ client: SynthClient) {
        observing = Task { [weak self] in
            for await _ in await client.changes() {
                guard let self else { return }
                await refresh(from: client)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func refresh(from client: SynthClient) async {
        let identifier = sessionID
        let snapshot = await client.viewState(for: identifier)
        guard self.client === client, sessionID == identifier else { return }
        connection = snapshot.connection
        state = snapshot.session
        interactions = snapshot.interactions
        for (key, status) in snapshot.activity where key != identifier {
            if let old = activity[key], status.finished > old.finished { completed.insert(key) }
        }
        activity = snapshot.activity
        if let identifier, state?.status?.isBusy != true && submitting == 0 {
            stopping.remove(identifier)
        }
    }

    func shutdown() async {
        isShuttingDown = true
        observing?.cancel()
        await client?.disconnect()
    }

    func retryProvider() async {
        guard canSwitch, !anyBusy, let client else { return }
        isOpening = true
        await client.disconnect()
        self.client = nil
        observing?.cancel()
        observing = nil
        let previous = sessionID
        let stored = recentSessions.first { $0.id == previous }
        if let previous, stored == nil {
            openedSessions.removeValue(forKey: previous)
        }
        isOpening = false
        await open(in: project, stored: stored)
        if let previous, let sessionID, previous != sessionID {
            drafts[sessionID] = drafts.removeValue(forKey: previous)
        }
    }

}

extension ConversationModel {
    func send() async {
        guard canSend, let client, let sessionID else { return }
        let text = draft
        drafts[sessionID] = ""
        failures.removeValue(forKey: sessionID)
        error = nil
        submissions[sessionID, default: 0] += 1
        defer {
            submissions[sessionID, default: 1] -= 1
            if submissions[sessionID] == 0 {
                submissions.removeValue(forKey: sessionID)
                stopping.remove(sessionID)
            }
        }
        do {
            _ = try await client.prompt(text, in: sessionID)
        } catch {
            if drafts[sessionID, default: ""].isEmpty { drafts[sessionID] = text }
            failures[sessionID] = error.localizedDescription
            if self.sessionID == sessionID { self.error = error.localizedDescription }
        }
        await refresh(from: client)
        if let opened = openedSessions[sessionID] {
            await loadGroup(opened.folder, refresh: true)
        }
    }

    func stop() async {
        guard canStop, let client, let sessionID else { return }
        stopping.insert(sessionID)
        do {
            try await client.cancelTurn(in: sessionID)
        } catch {
            stopping.remove(sessionID)
            if self.sessionID == sessionID { self.error = error.localizedDescription }
        }
    }

}

struct OpenedConversation: Identifiable {
    let id: String
    let folder: URL?
    let cwd: String
    let modes: [ACP.Mode]
}

struct ConversationSelection {
    let folder: URL?
    let sessionID: String?
}

struct ConversationGroup: Identifiable {
    let folder: URL?
    var sessions: [ACP.SessionInfo] = []
    var cursor: String?
    var loading = false
    var failure: String?
    var id: URL? { folder }
}

extension ConversationModel {
    var hasRequestedModels: Bool { modelsRequested }

    func fetchModels() async {
        guard canConfigure, let client, let sessionID else { return }
        modelError = nil
        modelsRequested = true
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            try await client.fetchModels(in: sessionID)
        } catch {
            modelError = error.localizedDescription
        }
    }

    func selectMode(_ mode: ACP.Mode) async {
        await configure { try await $0.setMode(mode.id, in: $1) }
    }

    func selectModel(_ model: Synth.Model) async {
        await configure { try await $0.setModel(model, in: $1) }
    }

    func selectEffort(_ effort: String) async {
        await configure { try await $0.setEffort(effort, in: $1) }
    }

    private func configure(_ operation: (SynthClient, String) async throws -> Void) async {
        guard canConfigure, let client, let sessionID else { return }
        isUpdatingConfiguration = true
        defer { isUpdatingConfiguration = false }
        do {
            try await operation(client, sessionID)
            await refresh(from: client)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func decide(_ request: RequestID, option: String) async {
        await respond { try await $0.decide(request, optionID: option) }
    }

    func answer(_ request: RequestID, fields: [String: String]) async {
        await respond { try await $0.answer(request, fields: fields) }
    }

    func decline(_ request: RequestID) async {
        await respond { try await $0.declineQuestion(request) }
    }

    private func respond(_ operation: (SynthClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await operation(client)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
